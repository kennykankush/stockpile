import SwiftUI
import InventoryKit
import LedgerKit

/// Everything that starts automatically — what each item actually runs, in
/// plain words. User-domain items get real (reversible) controls; privileged
/// items show a lock until the helper exists.
struct StartupView: View {
    @State private var model = StartupModel()
    @State private var pendingAction: StartupItem?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.sectionGap) {
                PageHeader(
                    title: "Startup",
                    subtitle: "Login items, agents, and daemons — and what each one actually runs."
                )

                if model.isLoading {
                    ProgressView("Reading launchd…")
                        .frame(maxWidth: .infinity, minHeight: 200)
                } else {
                    ForEach(StartupItem.Kind.allCases, id: \.self) { kind in
                        let items = model.items.filter { $0.kind == kind }
                        if !items.isEmpty {
                            section(kind: kind, items: items)
                        }
                    }
                }
            }
            .padding(Theme.pagePadding)
        }
        .task { await model.load() }
        .confirmationDialog(
            pendingAction.map { dialogTitle(for: $0) } ?? "",
            isPresented: Binding(get: { pendingAction != nil }, set: { if !$0 { pendingAction = nil } }),
            titleVisibility: .visible
        ) {
            if let item = pendingAction {
                Button(item.kind == .loginItem ? "Remove login item" : "Disable agent", role: .destructive) {
                    Task { await model.perform(on: item) }
                    pendingAction = nil
                }
                Button("Cancel", role: .cancel) { pendingAction = nil }
            }
        } message: {
            if let item = pendingAction {
                Text(item.kind == .loginItem
                     ? "The app itself is untouched — it just stops opening at login."
                     : "Reversible: the job is booted out and its plist renamed with a .DISABLED suffix.")
            }
        }
    }

    private func dialogTitle(for item: StartupItem) -> String {
        item.kind == .loginItem ? "Remove “\(item.name)” from login items?" : "Disable “\(item.name)”?"
    }

    private func section(kind: StartupItem.Kind, items: [StartupItem]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionLabel(
                text: kind.rawValue,
                trailing: kind.togglableHint
            )
            Card(padding: 6) {
                VStack(spacing: 0) {
                    ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                        StartupRow(item: item) { pendingAction = item }
                        if index < items.count - 1 {
                            Divider().overlay(Theme.hairline).padding(.leading, 50)
                        }
                    }
                }
            }
        }
    }
}

private extension StartupItem.Kind {
    var togglableHint: String? {
        switch self {
        case .loginItem: "removable"
        case .userAgent: "reversible toggle"
        case .globalAgent, .daemon: "root-owned — read-only for now"
        }
    }

    var symbol: String {
        switch self {
        case .loginItem: "person.crop.circle"
        case .userAgent: "gearshape"
        case .globalAgent: "gearshape.2"
        case .daemon: "lock.shield"
        }
    }
}

private struct StartupRow: View {
    let item: StartupItem
    let onAction: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 12) {
            IconTile(symbol: item.kind.symbol, tint: statusTint, size: 28)

            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 8) {
                    Text(item.name)
                        .font(.system(size: 13, weight: .medium))
                        .lineLimit(1)
                    if !item.enabled {
                        TierBadge(label: "Disabled", color: .secondary)
                    }
                    if item.keepAlive {
                        TierBadge(label: "Keeps alive", color: Theme.tierRegenerable)
                    }
                }
                Text("runs \(item.runs)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(item.programPath)
            }

            Spacer()

            if let pid = item.runningPID {
                HStack(spacing: 5) {
                    Circle().fill(Theme.tierCache).frame(width: 6, height: 6)
                    Text("PID \(pid)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }

            if item.togglable && item.enabled {
                Button(action: onAction) {
                    Image(systemName: item.kind == .loginItem ? "minus.circle" : "power")
                        .font(.callout)
                        .foregroundStyle(hovering ? Theme.tierData : .secondary)
                }
                .buttonStyle(.plain)
                .help(item.kind == .loginItem ? "Remove from login items" : "Disable (reversible)")
            } else if !item.togglable {
                Image(systemName: "lock")
                    .font(.caption)
                    .foregroundStyle(.quaternary)
                    .help("Root-owned — needs the privileged helper (coming later)")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(
            hovering ? Theme.surface2 : .clear,
            in: RoundedRectangle(cornerRadius: Theme.radiusRow, style: .continuous)
        )
        .onHover { hovering = $0 }
    }

    private var statusTint: Color {
        if !item.enabled { return .secondary }
        return item.runningPID != nil ? Theme.tierCache : Theme.purgeable
    }
}

@MainActor
@Observable
final class StartupModel {
    var items: [StartupItem] = []
    var isLoading = false

    func load() async {
        guard items.isEmpty else { return }
        isLoading = true
        let catalog = StartupCatalog()
        items = await Task.detached(priority: .userInitiated) { catalog.collect() }.value
        isLoading = false
    }

    func perform(on item: StartupItem) async {
        let actions = StartupActions()
        do {
            let description: String
            switch item.kind {
            case .loginItem:
                description = try actions.removeLoginItem(item)
            case .userAgent:
                description = try actions.disable(item)
            default:
                return
            }
            await LedgerStore.shared.append(LedgerEvent(kind: .startup, title: "Startup change", detail: description))
            items.removeAll()
            await load()
        } catch {
            // Surface failures honestly rather than pretending.
            await LedgerStore.shared.append(LedgerEvent(
                kind: .startup,
                title: "Startup change failed",
                detail: "\(item.name): \(error.localizedDescription)"
            ))
        }
    }
}
