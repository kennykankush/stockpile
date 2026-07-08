import SwiftUI
import ScannerKit
import RulesKit
import LedgerKit

/// A global signal that something was cleared, so other views (Descend)
/// can drop stale cached sizes without polling (F-005).
@MainActor
@Observable
final class Mutations {
    static let shared = Mutations()
    private(set) var generation = 0
    func bump() { generation += 1 }
}

/// Shared reclaimable state — built once, observed by Overview and Caches.
@MainActor
@Observable
final class ReclaimableModel {
    static let shared = ReclaimableModel()

    var items: [ReclaimableItem] = []
    var isLoading = false
    private var loaded = false
    /// Bumped on any mutation; an in-flight build with a stale generation
    /// discards its result rather than resurrecting a cleared row (F-006).
    private var generation = 0

    var totals: [Tier: Int64] { ReclaimableIndex.totals(of: items) }
    var grandTotal: Int64 { items.reduce(0) { $0 + $1.sizeBytes } }
    /// "Zero cost" excludes sensitive matches (login-bearing caches) — the
    /// honest free-to-clear figure (F-004).
    var freeToClearBytes: Int64 {
        items.filter { $0.rule.tier == .cache && !$0.rule.sensitive }.reduce(0) { $0 + $1.sizeBytes }
    }
    var regenerableBytes: Int64 {
        items.filter { $0.rule.tier == .regenerable }.reduce(0) { $0 + $1.sizeBytes }
    }
    var sensitiveBytes: Int64 {
        items.filter { $0.rule.sensitive }.reduce(0) { $0 + $1.sizeBytes }
    }

    func loadIfNeeded() async {
        guard !loaded, !isLoading else { return }
        await build()
        loaded = true
    }

    func refresh() async {
        for item in items {
            await SizeCache.shared.invalidate(subtree: item.path)
        }
        await build()
    }

    /// The core promise: move to Trash, record it, forget the measurement.
    /// Returns the ledger description, or throws.
    func clear(_ item: ReclaimableItem) async throws -> String {
        try TrashAction.moveToTrash(path: item.path)
        generation += 1                       // invalidate any in-flight build
        Mutations.shared.bump()               // tell Descend to drop stale sizes
        await SizeCache.shared.invalidate(subtree: item.path)
        await SizeCache.shared.flush()
        items.removeAll { $0.id == item.id }
        let description = "\(item.rule.title) (\(item.sizeBytes.bytesFormatted)) moved to Trash — recoverable. \(item.rule.regeneration)"
        await LedgerStore.shared.append(LedgerEvent(
            kind: .cleared,
            title: "Cleared \(item.rule.title)",
            detail: description,
            bytes: item.sizeBytes
        ))
        return description
    }

    private func build() async {
        isLoading = true
        let gen = generation
        var result: [ReclaimableItem] = []
        if let registry = try? RulesRegistry.bundled() {
            result = await ReclaimableIndex(registry: registry).build()
        }
        // A clear landed while we were measuring — discard the stale snapshot.
        guard gen == generation else { isLoading = false; return }
        items = result
        isLoading = false
        if let accounting = try? DiskAccounting.measure() {
            WidgetBridge.export(accounting: accounting, reclaimable: grandTotal)
        }
    }
}

/// The cache sector: everything Fleetwatch recognizes as reclaimable,
/// found for you — no descending required.
struct CachesView: View {
    @State private var model = ReclaimableModel.shared
    @State private var pendingClear: ReclaimableItem?
    @State private var lastAction: String?
    @State private var clearError: String?

    var body: some View {
        Screen(
            title: "Caches",
            subtitle: "Caches and build files safe to clear.",
            actions: {
                BarButton(label: "Refresh", symbol: "arrow.clockwise", disabled: model.isLoading) {
                    Task { await model.refresh() }
                }
            }
        ) {
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.sectionGap) {
                    if let lastAction {
                        Card(padding: 14) {
                            HStack(spacing: 10) {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundStyle(Theme.tierCache)
                                Text(lastAction)
                                    .font(.system(size: 12))
                                    .foregroundStyle(.secondary)
                                Spacer()
                                Button("Dismiss") { self.lastAction = nil }
                                    .buttonStyle(.plain)
                                    .font(.system(size: 11))
                                    .foregroundStyle(.tertiary)
                            }
                        }
                    }
                    if let clearError {
                        Card(padding: 14) {
                            HStack(spacing: 10) {
                                Image(systemName: "exclamationmark.triangle.fill")
                                    .foregroundStyle(Theme.tierRegenerable)
                                Text(clearError)
                                    .font(.system(size: 12))
                                    .foregroundStyle(.secondary)
                                Spacer()
                                Button("Dismiss") { self.clearError = nil }
                                    .buttonStyle(.plain)
                                    .font(.system(size: 11))
                                    .foregroundStyle(.tertiary)
                            }
                        }
                    }
                    if model.isLoading && model.items.isEmpty {
                        VStack(spacing: 12) {
                            ProgressView()
                            Text("Finding reclaimable space…")
                                .font(.callout)
                                .foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity, minHeight: 220)
                    } else {
                        StatStrip(columns: [
                            .init(
                                label: "Free to clear",
                                value: model.freeToClearBytes.bytesFormatted,
                                caption: "Caches. Rebuild on their own.",
                                tint: Theme.tierCache
                            ),
                            .init(
                                label: "If you rebuild",
                                value: model.regenerableBytes.bytesFormatted,
                                caption: "Build files. Restored on next build.",
                                tint: Theme.tierRegenerable
                            ),
                            .init(
                                label: "Review first",
                                value: model.sensitiveBytes.bytesFormatted,
                                caption: "May hold logins. Check first.",
                                tint: Theme.tierData
                            ),
                        ])
                        tierSection(.cache, label: "Free to clear", caption: "rebuild on their own")
                        tierSection(.regenerable, label: "Costs a rebuild", caption: "restored on next build")
                    }
                }
                .padding(28)
            }
        }
        .task { await model.loadIfNeeded() }
        .confirmationDialog(
            pendingClear.map { "Clear \($0.rule.title)? (\($0.sizeBytes.bytesFormatted))" } ?? "",
            isPresented: Binding(get: { pendingClear != nil }, set: { if !$0 { pendingClear = nil } }),
            titleVisibility: .visible
        ) {
            if let item = pendingClear {
                if let owner = item.rule.ownerAppBundleID, let running = RunningApps.app(bundleID: owner) {
                    Button("Quit \(running.localizedName ?? "app") & Clear", role: .destructive) {
                        perform(item, quitting: running)
                    }
                } else {
                    Button("Move to Trash", role: .destructive) {
                        perform(item, quitting: nil)
                    }
                }
                Button("Cancel", role: .cancel) { pendingClear = nil }
            }
        } message: {
            if let item = pendingClear {
                if item.rule.sensitive {
                    Text("⚠︎ This lives in a cache folder but may hold login sessions or other data you'd have to re-enter. \(item.rule.regeneration) Moved to Trash — recoverable until you empty it.")
                } else {
                    Text("\(item.rule.regeneration) Moved to Trash — recoverable until you empty it.")
                }
            }
        }
    }

    private func perform(_ item: ReclaimableItem, quitting owner: NSRunningApplication?) {
        pendingClear = nil
        Task {
            if let owner {
                let quit = await RunningApps.quitAndWait(owner)
                if !quit {
                    clearError = "\(owner.localizedName ?? "The app") is still running — clear aborted so its cache isn't half-rewritten. Quit it and retry."
                    return
                }
            }
            do {
                lastAction = try await model.clear(item)
                clearError = nil
            } catch {
                // F-009: failures are recorded, not just shown.
                await LedgerStore.shared.append(LedgerEvent(
                    kind: .cleared,
                    title: "Clear failed: \(item.rule.title)",
                    detail: error.localizedDescription
                ))
                clearError = "Couldn't clear \(item.rule.title): \(error.localizedDescription)"
            }
        }
    }

    @ViewBuilder
    private func tierSection(_ tier: Tier, label: String, caption: String) -> some View {
        let items = model.items.filter { $0.rule.tier == tier }
        if !items.isEmpty {
            let largest = items.map(\.sizeBytes).max() ?? 1
            VStack(alignment: .leading, spacing: 8) {
                SectionLabel(text: label, trailing: caption)
                Card(padding: 6) {
                    VStack(spacing: 0) {
                        ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                            ReclaimableRow(
                                item: item,
                                fractionOfLargest: largest > 0 ? Double(item.sizeBytes) / Double(largest) : 0
                            ) { pendingClear = item }
                            if index < items.count - 1 {
                                Divider().overlay(Theme.hairline).padding(.leading, 50)
                            }
                        }
                    }
                }
            }
        }
    }
}

private struct ReclaimableRow: View {
    let item: ReclaimableItem
    let fractionOfLargest: Double
    let onClear: () -> Void
    @State private var hovering = false

    private var abbreviatedPath: String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return item.path.hasPrefix(home)
            ? "~" + item.path.dropFirst(home.count)
            : item.path
    }

    var body: some View {
        HStack(spacing: 12) {
            IconTile(
                symbol: item.rule.sensitive ? "exclamationmark.shield" : (item.rule.tier == .cache ? "leaf" : "hammer"),
                tint: item.rule.sensitive ? Theme.tierData : item.rule.tier.color,
                size: 26
            )
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(item.rule.title)
                        .font(.system(size: 13, weight: .medium))
                    if item.rule.sensitive {
                        TierBadge(label: "Review", color: Theme.tierData)
                    }
                }
                Text(abbreviatedPath)
                    .font(.system(size: 10.5))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 12)
            if hovering {
                Text(item.rule.regeneration)
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
            SizeBar(fraction: fractionOfLargest, tint: item.rule.tier.color.opacity(0.75))
            Text(item.sizeBytes.bytesFormatted)
                .font(.system(size: 13, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .frame(width: 76, alignment: .trailing)

            Button(action: onClear) {
                Image(systemName: "trash")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(hovering ? Theme.tierData : Theme.inkTertiary.opacity(0.4))
                    .frame(width: 24, height: 24)
                    .background(hovering ? Theme.surface2 : .clear, in: RoundedRectangle(cornerRadius: 6))
            }
            .buttonStyle(Pressable())
            .help("Move to Trash — recoverable")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .help(item.rule.explanation)
    }
}
