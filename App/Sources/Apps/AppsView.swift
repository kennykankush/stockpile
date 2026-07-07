import SwiftUI
import AppKit
import InventoryKit
import ScannerKit

/// The totality of installed software, categorized by where it came from —
/// because the source determines the correct uninstall path.
struct AppsView: View {
    @State private var model = AppsModel()
    @State private var filter: SourceFilter = .all

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
                    tableHeader
                    Divider().overlay(Theme.hairline)
                    appList
                }
            }
        }
        .task { await model.load() }
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
                    AppRow(app: app)
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

/// Loads the census fast (names + sources), then streams sizes in.
@MainActor
@Observable
final class AppsModel {
    var apps: [InstalledApp] = []
    var sizingInFlight = 0
    private var loaded = false

    func load() async {
        guard !loaded else { return }
        loaded = true

        let census = AppCensus()
        let collected = await Task.detached(priority: .userInitiated) {
            (census.collectApps() + census.collectFormulae())
                .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        }.value

        apps = collected

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
