import SwiftUI
import ScannerKit
import RulesKit

/// Shared reclaimable state — built once, observed by Overview and Caches.
@MainActor
@Observable
final class ReclaimableModel {
    static let shared = ReclaimableModel()

    var items: [ReclaimableItem] = []
    var isLoading = false
    private var loaded = false

    var totals: [Tier: Int64] { ReclaimableIndex.totals(of: items) }
    var grandTotal: Int64 { items.reduce(0) { $0 + $1.sizeBytes } }

    func loadIfNeeded() async {
        guard !loaded, !isLoading else { return }
        await build()
        loaded = true
    }

    func refresh() async {
        // Forget measurements for every listed location, then re-measure.
        for item in items {
            await SizeCache.shared.invalidate(subtree: item.path)
        }
        await build()
    }

    private func build() async {
        isLoading = true
        if let registry = try? RulesRegistry.bundled() {
            let index = ReclaimableIndex(registry: registry)
            items = await index.build()
        }
        isLoading = false
    }
}

/// The cache sector: everything Stockpile recognizes as reclaimable,
/// found for you — no descending required.
struct CachesView: View {
    @State private var model = ReclaimableModel.shared

    var body: some View {
        Screen(
            title: "Caches",
            subtitle: "Every reclaimable location the registry recognizes — found for you.",
            actions: {
                BarButton(label: "Refresh", symbol: "arrow.clockwise", disabled: model.isLoading) {
                    Task { await model.refresh() }
                }
            }
        ) {
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.sectionGap) {
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
                                value: (model.totals[.cache] ?? 0).bytesFormatted,
                                caption: "Pure caches — clearing costs nothing.",
                                tint: Theme.tierCache
                            ),
                            .init(
                                label: "If you rebuild",
                                value: (model.totals[.regenerable] ?? 0).bytesFormatted,
                                caption: "Build artifacts and dependencies — one install away.",
                                tint: Theme.tierRegenerable
                            ),
                        ])
                        tierSection(.cache, label: "Free to clear", caption: "regenerates itself — zero cost")
                        tierSection(.regenerable, label: "Costs a rebuild", caption: "restorable with a reinstall or recompile")
                    }
                }
                .padding(28)
            }
        }
        .task { await model.loadIfNeeded() }
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
                            )
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
                symbol: item.rule.tier == .cache ? "leaf" : "hammer",
                tint: item.rule.tier.color,
                size: 26
            )
            VStack(alignment: .leading, spacing: 1) {
                Text(item.rule.title)
                    .font(.system(size: 13, weight: .medium))
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
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .help(item.rule.explanation)
    }
}
