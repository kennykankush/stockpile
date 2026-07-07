import SwiftUI
import AppKit
import InventoryKit
import ScannerKit
import LedgerKit

/// A staged uninstall: the app plus what we found scattered around.
struct UninstallPlan: Identifiable {
    var id: String { app.id }
    let app: InstalledApp
    let leftovers: [Leftover]

    var totalBytes: Int64 {
        (app.sizeBytes ?? 0) + leftovers.reduce(0) { $0 + $1.sizeBytes }
    }

    var methodDescription: String {
        switch app.source {
        case .homebrewCask: "via brew uninstall --zap (then leftover sweep)"
        case .homebrewFormula: "via brew uninstall"
        case .appStore, .direct: "app + leftovers to Trash — recoverable"
        }
    }
}

/// The totality of installed software, categorized by where it came from —
/// because the source determines the correct uninstall path.
struct AppsView: View {
    @State private var model = AppsModel()
    @State private var filter: SourceFilter = .all
    @State private var plan: UninstallPlan?
    @State private var banner: (message: String, isError: Bool)?

    enum SourceFilter: String, CaseIterable, Identifiable {
        case all = "All"
        case appStore = "App Store"
        case cask = "Brew Cask"
        case formula = "Brew CLI"
        case direct = "Direct"

        var id: String { rawValue }

        func matches(_ app: InstalledApp) -> Bool {
            switch self {
            case .all: true
            case .appStore: app.source == .appStore
            case .cask: app.source == .homebrewCask
            case .formula: app.source == .homebrewFormula
            case .direct: app.source == .direct
            }
        }
    }

    private var filtered: [InstalledApp] {
        model.apps.filter { filter.matches($0) }
    }

    var body: some View {
        Screen(title: "Apps", subtitle: subtitle, actions: { filterChips }) {
            if model.apps.isEmpty {
                ProgressView("Taking the census…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                VStack(spacing: 0) {
                    if let banner {
                        HStack(spacing: 10) {
                            Image(systemName: banner.isError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                                .foregroundStyle(banner.isError ? Theme.tierRegenerable : Theme.tierCache)
                            Text(banner.message)
                                .font(.system(size: 12))
                                .foregroundStyle(.secondary)
                            Spacer()
                            Button("Dismiss") { self.banner = nil }
                                .buttonStyle(.plain)
                                .font(.system(size: 11))
                                .foregroundStyle(.tertiary)
                        }
                        .padding(.horizontal, 28)
                        .padding(.vertical, 10)
                        Divider().overlay(Theme.hairline)
                    }
                    if !model.orphans.isEmpty {
                        ghostsSection
                        Divider().overlay(Theme.hairline)
                    }
                    tableHeader
                    Divider().overlay(Theme.hairline)
                    appList
                }
            }
        }
        .task { await model.load() }
        .confirmationDialog(
            plan.map { "Uninstall \($0.app.name)? (\($0.totalBytes.bytesFormatted) total)" } ?? "",
            isPresented: Binding(get: { plan != nil }, set: { if !$0 { plan = nil } }),
            titleVisibility: .visible
        ) {
            if let plan {
                if let id = plan.app.bundleIdentifier, let running = RunningApps.app(bundleID: id) {
                    Button("Quit & Uninstall", role: .destructive) {
                        perform(plan, quitting: running)
                    }
                } else {
                    Button("Uninstall", role: .destructive) {
                        perform(plan, quitting: nil)
                    }
                }
                Button("Cancel", role: .cancel) { self.plan = nil }
            }
        } message: {
            if let plan {
                Text("\(plan.methodDescription). Found \(plan.leftovers.count) leftover location\(plan.leftovers.count == 1 ? "" : "s") (\(plan.leftovers.reduce(0) { $0 + $1.sizeBytes }.bytesFormatted)) — swept too.")
            }
        }
    }

    private func stage(_ app: InstalledApp) {
        Task {
            let leftovers = await Task.detached(priority: .userInitiated) {
                LeftoverLocator.find(bundleIdentifier: app.bundleIdentifier, appName: app.name)
            }.value
            plan = UninstallPlan(app: app, leftovers: leftovers)
        }
    }

    private func perform(_ plan: UninstallPlan, quitting owner: NSRunningApplication?) {
        self.plan = nil
        Task {
            if let owner {
                let quit = await RunningApps.quitAndWait(owner)
                if !quit {
                    banner = (message: "\(plan.app.name) is still running — uninstall aborted. Quit it and try again.", isError: true)
                    return
                }
            }
            do {
                let outcome = try await Task.detached(priority: .userInitiated) {
                    try UninstallAction.uninstall(plan.app, leftovers: plan.leftovers, brew: .local())
                }.value
                await LedgerStore.shared.append(LedgerEvent(
                    kind: .cleared,
                    title: "Uninstalled \(plan.app.name)",
                    detail: outcome.description,
                    bytes: plan.totalBytes
                ))
                model.apps.removeAll { $0.id == plan.app.id }
                banner = (message: "\(outcome.description) — \(plan.totalBytes.bytesFormatted) freed.", isError: false)
            } catch {
                // F-009: failures are ledgered, not just bannered.
                await LedgerStore.shared.append(LedgerEvent(
                    kind: .cleared,
                    title: "Uninstall failed: \(plan.app.name)",
                    detail: error.localizedDescription
                ))
                banner = (message: "Couldn't uninstall \(plan.app.name): \(error.localizedDescription)", isError: true)
            }
        }
    }

    @State private var ghostsExpanded = false

    private var ghostsSection: some View {
        VStack(spacing: 0) {
            Button { withAnimation(.snappy) { ghostsExpanded.toggle() } } label: {
                HStack(spacing: 10) {
                    IconTile(symbol: "moon.stars", tint: Theme.purgeable, size: 26)
                    VStack(alignment: .leading, spacing: 1) {
                        Text("\(model.orphans.count) ghost\(model.orphans.count == 1 ? "" : "s") — leftovers from deleted apps")
                            .font(.system(size: 13, weight: .medium))
                        Text("\(model.orphanTotal.bytesFormatted) · residue no uninstaller catches. Review before clearing.")
                            .font(.system(size: 11)).foregroundStyle(.tertiary)
                    }
                    Spacer()
                    Image(systemName: ghostsExpanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                }
                .padding(.horizontal, 28).padding(.vertical, 12)
            }
            .buttonStyle(.plain)

            if ghostsExpanded {
                VStack(spacing: 2) {
                    ForEach(model.orphans) { orphan in
                        GhostRow(orphan: orphan) { Task { await model.clearOrphan(orphan) } }
                    }
                }
                .padding(.horizontal, 28).padding(.bottom, 12)
            }
        }
    }

    private var tableHeader: some View {
        HStack(spacing: 12) {
            Color.clear.frame(width: 28, height: 1)
            Text("APPLICATION")
                .frame(maxWidth: .infinity, alignment: .leading)
            Text("SOURCE")
                .frame(width: 100, alignment: .leading)
            Text("LAST USED")
                .frame(width: 100, alignment: .trailing)
            Text("SIZE")
                .frame(width: 80, alignment: .trailing)
        }
        .font(.system(size: 10, weight: .semibold))
        .tracking(1.2)
        .foregroundStyle(.tertiary)
        .padding(.horizontal, 40)
        .padding(.vertical, 10)
    }

    private var subtitle: String {
        var parts = ["\(filtered.count) installed"]
        let sizes = filtered.compactMap(\.sizeBytes)
        if !sizes.isEmpty {
            parts.append(sizes.reduce(0, +).bytesFormatted)
        }
        if model.sizingInFlight > 0 {
            parts.append("sizing \(model.sizingInFlight)…")
        }
        return parts.joined(separator: " · ")
    }

    private var filterChips: some View {
        HStack(spacing: 2) {
            ForEach(SourceFilter.allCases) { f in
                let count = model.apps.filter { f.matches($0) }.count
                let selected = filter == f
                Button {
                    filter = f
                } label: {
                    HStack(spacing: 6) {
                        Text(f.rawValue)
                            .font(.system(size: 12, weight: selected ? .semibold : .regular))
                        Text("\(count)")
                            .font(.system(size: 11, weight: .semibold))
                            .monospacedDigit()
                            .foregroundStyle(selected ? Theme.accent : .secondary)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(
                        selected ? Theme.surface3 : .clear,
                        in: RoundedRectangle(cornerRadius: 8, style: .continuous)
                    )
                    .overlay {
                        if selected {
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .strokeBorder(Theme.hairlineStrong, lineWidth: 1)
                        }
                    }
                }
                .buttonStyle(Pressable())
            }
        }
        .padding(3)
        .background(Theme.surface1, in: RoundedRectangle(cornerRadius: 11, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous).strokeBorder(Theme.hairline, lineWidth: 1))
    }

    private var appList: some View {
        ScrollView {
            LazyVStack(spacing: 2) {
                ForEach(filtered) { app in
                    AppRow(app: app) { stage(app) }
                }
            }
            .padding(.horizontal, 28)
            .padding(.vertical, 12)
        }
        .scrollIndicators(.hidden)
    }
}

private struct AppRow: View {
    let app: InstalledApp
    let onUninstall: () -> Void

    var body: some View {
        HoverRow { hovering in
        HStack(spacing: 12) {
            icon
                .frame(width: 28, height: 28)

            VStack(alignment: .leading, spacing: 1) {
                Text(app.name)
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(1)
                Text(app.bundlePath)
                    .font(.system(size: 10.5))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .opacity(hovering ? 1 : 0)
            }

            Spacer()

            HStack {
                TierBadge(label: app.source.displayName, color: sourceColor)
                Spacer(minLength: 0)
            }
            .frame(width: 100)

            Group {
                if let lastUsed = app.lastUsed {
                    Text(lastUsed, format: .relative(presentation: .named))
                } else {
                    Text("—")
                }
            }
            .font(.system(size: 11))
            .foregroundStyle(.tertiary)
            .lineLimit(1)
            .frame(width: 100, alignment: .trailing)

            Group {
                if let size = app.sizeBytes {
                    Text(size.bytesFormatted)
                } else {
                    Text("…").foregroundStyle(.tertiary)
                }
            }
            .font(.system(size: 13, weight: .semibold, design: .rounded))
            .monospacedDigit()
            .frame(width: 80, alignment: .trailing)

            Button(action: onUninstall) {
                Image(systemName: "trash")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(hovering ? Theme.tierData : .clear)
                    .frame(width: 22, height: 22)
            }
            .buttonStyle(Pressable())
            .disabled(!hovering)
            .help("Uninstall — the correct way for its source, leftovers swept")
        }
        }
    }

    @ViewBuilder
    private var icon: some View {
        if app.source == .homebrewFormula {
            IconTile(symbol: "terminal", size: 28)
        } else {
            Image(nsImage: NSWorkspace.shared.icon(forFile: app.bundlePath))
                .resizable()
                .aspectRatio(contentMode: .fit)
        }
    }

    private var sourceColor: Color {
        switch app.source {
        case .appStore: Theme.purgeable
        case .homebrewCask: Theme.tierCache
        case .homebrewFormula: Theme.accent
        case .direct: Theme.tierRegenerable
        }
    }
}

private struct GhostRow: View {
    let orphan: Orphan
    let onClear: () -> Void
    @State private var hovering = false

    private var abbreviated: String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return orphan.path.hasPrefix(home) ? "~" + orphan.path.dropFirst(home.count) : orphan.path
    }

    var body: some View {
        HStack(spacing: 12) {
            IconTile(symbol: "questionmark.folder", size: 26)
            VStack(alignment: .leading, spacing: 1) {
                Text(orphan.bundleID).font(.system(size: 12, weight: .medium)).lineLimit(1)
                Text(abbreviated).font(.system(size: 10.5)).foregroundStyle(.tertiary).lineLimit(1).truncationMode(.middle)
            }
            Spacer(minLength: 12)
            Text(orphan.sizeBytes.bytesFormatted)
                .font(.system(size: 12, weight: .semibold, design: .rounded)).monospacedDigit()
            Button(action: onClear) {
                Image(systemName: "trash")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(hovering ? Theme.tierData : Color.white.opacity(0.15))
                    .frame(width: 24, height: 24)
            }
            .buttonStyle(Pressable())
            .help("Move this leftover to Trash — recoverable")
        }
        .padding(.horizontal, 12).padding(.vertical, 7)
        .background(hovering ? Theme.surface2 : .clear, in: RoundedRectangle(cornerRadius: Theme.radiusRow))
        .onHover { hovering = $0 }
    }
}

/// Loads the census fast (names + sources), then streams sizes in.
@MainActor
@Observable
final class AppsModel {
    var apps: [InstalledApp] = []
    var orphans: [Orphan] = []
    var sizingInFlight = 0
    private var loaded = false

    var orphanTotal: Int64 { orphans.reduce(0) { $0 + $1.sizeBytes } }

    func clearOrphan(_ orphan: Orphan) async {
        do {
            try TrashAction.moveToTrash(path: orphan.path)
            orphans.removeAll { $0.id == orphan.id }
            await LedgerStore.shared.append(LedgerEvent(
                kind: .cleared,
                title: "Cleared ghost: \(orphan.bundleID)",
                detail: "Leftover from a deleted app (\(orphan.sizeBytes.bytesFormatted)) moved to Trash — recoverable.",
                bytes: orphan.sizeBytes
            ))
        } catch {
            await LedgerStore.shared.append(LedgerEvent(
                kind: .cleared, title: "Ghost clear failed: \(orphan.bundleID)", detail: error.localizedDescription))
        }
    }

    func load() async {
        guard !loaded else { return }
        loaded = true

        let census = AppCensus()
        let collected = await Task.detached(priority: .userInitiated) {
            (census.collectApps() + census.collectFormulae())
                .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        }.value

        apps = collected

        // Ghost hunt: residue from apps no longer installed.
        let installedIDs = Set(collected.compactMap(\.bundleIdentifier))
        Task.detached(priority: .utility) {
            let found = OrphanFinder.find(installedBundleIDs: installedIDs)
            await MainActor.run { self.orphans = found }
        }

        // Cache pass first: bundle mtimes change on update, so unchanged
        // apps get instant sizes with zero disk walking.
        var misses: [InstalledApp] = []
        for (index, app) in collected.enumerated() {
            let url = URL(fileURLWithPath: app.bundlePath)
            let mtime = AllocatedSize.modificationTime(of: url)
            if let hit = await SizeCache.shared.lookup(path: app.bundlePath, mtime: mtime) {
                apps[index].sizeBytes = hit.size
            } else {
                misses.append(app)
            }
        }
        apps.sort { ($0.sizeBytes ?? -1, $1.name) > ($1.sizeBytes ?? -1, $0.name) }
        sizingInFlight = misses.count
        guard !misses.isEmpty else { return }

        await withTaskGroup(of: (String, Int64).self) { group in
            for app in misses {
                group.addTask {
                    let url = URL(fileURLWithPath: app.bundlePath)
                    let mtime = AllocatedSize.modificationTime(of: url)
                    let size = AllocatedSize.measure(url)
                    await SizeCache.shared.store(path: app.bundlePath, mtime: mtime, size: size)
                    return (app.bundlePath, size)
                }
            }
            var completed = 0
            for await (path, size) in group {
                if let index = apps.firstIndex(where: { $0.bundlePath == path }) {
                    apps[index].sizeBytes = size
                }
                sizingInFlight -= 1
                completed += 1
                // Re-sort in batches so the list doesn't churn on every result.
                if completed.isMultiple(of: 12) || sizingInFlight == 0 {
                    apps.sort {
                        ($0.sizeBytes ?? -1, $1.name) > ($1.sizeBytes ?? -1, $0.name)
                    }
                }
            }
        }
        await SizeCache.shared.flush()
    }
}
