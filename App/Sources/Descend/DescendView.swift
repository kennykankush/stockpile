import SwiftUI
import ScannerKit
import RulesKit

/// Session-level scan cache: a folder is sized once per launch, then every
/// revisit is instant. Refresh re-measures on demand.
@MainActor
@Observable
final class DescendModel {
    var path: [URL] = [FileManager.default.homeDirectoryForCurrentUser]
    var entries: [ScannedEntry] = []
    var isScanning = false
    var scanError: String?

    private var cache: [String: [ScannedEntry]] = [:]

    var current: URL { path.last ?? FileManager.default.homeDirectoryForCurrentUser }

    func show(_ url: URL) async {
        scanError = nil
        if let hit = cache[url.path] {
            entries = hit
            return
        }
        await scan(url)
    }

    /// Refresh forgets the persistent measurements for this subtree too —
    /// the one honest way to re-measure after deep changes.
    func refresh() async {
        cache.removeValue(forKey: current.path)
        if let registry = try? RulesRegistry.bundled() {
            await DirectoryScanner(registry: registry).invalidate(subtree: current)
        }
        await scan(current)
    }

    /// The most stale measurement on screen, for the honesty footnote.
    var oldestMeasurement: Date? {
        entries.map(\.measuredAt).min()
    }

    private func scan(_ url: URL) async {
        isScanning = true
        do {
            let registry = try RulesRegistry.bundled()
            let scanner = DirectoryScanner(registry: registry)
            let result = try await scanner.children(of: url)
            cache[url.path] = result
            entries = result
        } catch {
            scanError = "Can't read \(url.lastPathComponent): \(error.localizedDescription)"
        }
        isScanning = false
    }
}

/// The inward granulizer: click a folder and it becomes the canvas.
struct DescendView: View {
    @State private var model = DescendModel()

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .center) {
                breadcrumb
                Spacer()
                if let oldest = model.oldestMeasurement, !model.isScanning {
                    Text("measured \(oldest, format: .relative(presentation: .named))")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .padding(.trailing, 8)
                }
                Button {
                    Task { await model.refresh() }
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                        .font(.callout)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .disabled(model.isScanning)
                .help("Re-measure this folder")
            }

            if model.isScanning {
                VStack(spacing: 12) {
                    ProgressView()
                    Text("Sizing \(model.current.lastPathComponent)…")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Text("Measured once per session — revisits are instant.")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let scanError = model.scanError {
                Card {
                    Label(scanError, systemImage: "lock")
                        .foregroundStyle(Theme.tierRegenerable)
                }
                Spacer()
            } else {
                entryList
            }
        }
        .padding(Theme.pagePadding)
        .task(id: model.current) { await model.show(model.current) }
    }

    private var breadcrumb: some View {
        HStack(spacing: 5) {
            if model.path.count > 1 {
                Button {
                    _ = model.path.removeLast()
                } label: {
                    Image(systemName: "chevron.left")
                        .font(.callout.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 24, height: 24)
                        .background(Theme.surface2, in: RoundedRectangle(cornerRadius: 7))
                }
                .buttonStyle(.plain)
                .padding(.trailing, 6)
            }

            ForEach(Array(model.path.enumerated()), id: \.element) { index, url in
                if index > 0 {
                    Image(systemName: "chevron.compact.right")
                        .font(.caption)
                        .foregroundStyle(.quaternary)
                }
                Button {
                    model.path = Array(model.path.prefix(index + 1))
                } label: {
                    Text(url.lastPathComponent.isEmpty ? "/" : url.lastPathComponent)
                        .font(.system(size: 19, weight: index == model.path.count - 1 ? .semibold : .regular))
                        .foregroundStyle(index == model.path.count - 1 ? .primary : .secondary)
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var entryList: some View {
        ScrollView {
            LazyVStack(spacing: 4) {
                let largest = model.entries.first?.sizeBytes ?? 1
                ForEach(model.entries) { entry in
                    EntryRow(
                        entry: entry,
                        fractionOfLargest: largest > 0 ? Double(entry.sizeBytes) / Double(largest) : 0
                    )
                    .onTapGesture {
                        guard entry.isDirectory else { return }
                        model.path.append(entry.url)
                    }
                }
            }
        }
        .scrollIndicators(.hidden)
    }
}

private struct EntryRow: View {
    let entry: ScannedEntry
    let fractionOfLargest: Double

    var body: some View {
        HoverRow {
        HStack(spacing: 12) {
            IconTile(
                symbol: entry.isDirectory ? "folder.fill" : "doc",
                tint: entry.rule?.tier.color,
                size: 28
            )

            VStack(alignment: .leading, spacing: 1) {
                Text(entry.name)
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(1)
                if let rule = entry.rule {
                    Text("\(rule.title) — \(rule.regeneration)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            Spacer()

            if let rule = entry.rule {
                TierBadge(label: rule.tier.badgeLabel, color: rule.tier.color)
            }

            VStack(alignment: .trailing, spacing: 4) {
                Text(entry.sizeBytes.bytesFormatted)
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                Capsule()
                    .fill((entry.rule?.tier.color ?? .white).opacity(entry.rule == nil ? 0.18 : 0.55))
                    .frame(width: max(64 * fractionOfLargest, 2), height: 2)
                    .frame(width: 64, alignment: .trailing)
            }
            .frame(width: 84, alignment: .trailing)
        }
        }
    }
}
