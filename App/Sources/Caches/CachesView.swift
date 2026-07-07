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
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.sectionGap) {
                HStack(alignment: .top) {
                    PageHeader(
                        title: "Caches",
                        subtitle: "Every reclaimable location the registry recognizes — found, sized, and explained."
                    )
                    Spacer()
                    Button {
                        Task { await model.refresh() }
                    } label: {
                        Label("Refresh", systemImage: "arrow.clockwise")
                            .font(.callout)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .disabled(model.isLoading)
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
                    totalsRow
                    tierSection(.cache, label: "Free to clear", caption: "regenerates itself — zero cost")
                    tierSection(.regenerable, label: "Costs a rebuild", caption: "restorable with a reinstall or recompile")
                }
            }
            .padding(Theme.pagePadding)
        }
        .task { await model.loadIfNeeded() }
    }

    private var totalsRow: some View {
        HStack(spacing: 14) {
            StatTile(
                symbol: "leaf",
                tint: Theme.tierCache,
                label: "Free to clear",
                value: (model.totals[.cache] ?? 0).bytesFormatted,
                caption: "Pure caches — clearing costs nothing."
            )
            StatTile(
                symbol: "hammer",
                tint: Theme.tierRegenerable,
                label: "If you rebuild",
                value: (model.totals[.regenerable] ?? 0).bytesFormatted,
                caption: "Build artifacts and dependencies — one install away."
            )
        }
    }

    @ViewBuilder
    private func tierSection(_ tier: Tier, label: String, caption: String) -> some View {
        let items = model.items.filter { $0.rule.tier == tier }
        if !items.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                SectionLabel(text: label, trailing: caption)
                Card(padding: 6) {
                    VStack(spacing: 0) {
                        ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                            ReclaimableRow(item: item)
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
                size: 28
            )
            VStack(alignment: .leading, spacing: 1) {
                Text(item.rule.title)
                    .font(.system(size: 13, weight: .medium))
                Text(abbreviatedPath)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer()
            Text(item.sizeBytes.bytesFormatted)
                .font(.system(size: 13, weight: .semibold, design: .rounded))
                .monospacedDigit()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .help(item.rule.regeneration)
    }
}
