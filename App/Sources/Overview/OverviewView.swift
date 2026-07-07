import SwiftUI
import ScannerKit
import RulesKit
import LedgerKit

/// Tracks once-per-launch work.
@MainActor
enum AppRuntime {
    static var snapshotRecorded = false
    static var memoryRecorded = false
    static var heatRecorded = false
}

/// The honest numbers: one protagonist numeral, a metric stack beside it,
/// and the reclaimable strip below. Both accountings, always.
struct OverviewView: View {
    var onNavigate: (AppSection) -> Void = { _ in }
    @State private var accounting: DiskAccounting?
    @State private var loadError: String?
    @State private var reclaimable = ReclaimableModel.shared
    @State private var previousSnapshot: LedgerEvent?
    @State private var reportCopied = false
    @State private var glance = SystemGlance()
    @State private var updates = UpdateChecker.shared

    var body: some View {
        Screen(
            title: "Overview",
            subtitle: "Your disk, honestly — physical bytes and what's effectively yours.",
            actions: {
                BarButton(label: reportCopied ? "Copied ✓" : "Copy Report", symbol: "doc.on.doc") {
                    Task {
                        let report = await SystemReport.build(reclaimable: reclaimable.grandTotal)
                        SystemReport.copyToClipboard(report)
                        reportCopied = true
                        try? await Task.sleep(for: .seconds(2))
                        reportCopied = false
                    }
                }
            }
        ) {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    SetupCard()

                    if let latest = updates.latestVersion {
                        UpdateBanner(version: latest)
                    }

                    if !glance.tiles.isEmpty {
                        glanceRow
                    }

                    if let accounting {
                        CapacityHero(accounting: accounting)
                        diffLine(accounting)
                        reclaimableStrip
                    } else if let loadError {
                        Card {
                            Label(loadError, systemImage: "exclamationmark.triangle")
                                .foregroundStyle(Theme.tierRegenerable)
                        }
                    } else {
                        ProgressView("Measuring…")
                            .frame(maxWidth: .infinity, minHeight: 240)
                    }
                }
                .padding(28)
            }
        }
        .task { await load() }
    }

    private var glanceRow: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 14), count: glance.tiles.count), spacing: 14) {
            ForEach(glance.tiles) { tile in
                Button { onNavigate(tile.section) } label: {
                    Card(padding: 16) {
                        VStack(alignment: .leading, spacing: 10) {
                            HStack(spacing: 8) {
                                IconTile(symbol: tile.symbol, tint: tile.tint.color, size: 24)
                                Text(tile.label.uppercased())
                                    .font(.system(size: 11, weight: .semibold)).tracking(1.3).foregroundStyle(.secondary)
                                Spacer()
                                Image(systemName: "chevron.right").font(.system(size: 10, weight: .semibold)).foregroundStyle(.quaternary)
                            }
                            Text(tile.value)
                                .font(.system(size: 22, weight: .semibold, design: .rounded)).tracking(-0.4)
                                .foregroundStyle(tile.tint.color).monospacedDigit().lineLimit(1)
                            Text(tile.detail)
                                .font(.system(size: 11)).foregroundStyle(.tertiary).lineLimit(1)
                        }
                    }
                }
                .buttonStyle(Pressable())
            }
        }
    }

    private var reclaimableStrip: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionLabel(
                text: "Reclaimable",
                trailing: reclaimable.items.isEmpty ? "finding recognized locations…" : "across \(reclaimable.items.count) locations — see Caches"
            )
            StatStrip(columns: [
                .init(
                    label: "Total",
                    value: reclaimable.items.isEmpty ? "…" : reclaimable.grandTotal.bytesFormatted,
                    caption: "Everything the registry recognizes as safe to let go.",
                    tint: Theme.accent
                ),
                .init(
                    label: "Free to clear",
                    value: reclaimable.items.isEmpty ? "…" : (reclaimable.totals[.cache] ?? 0).bytesFormatted,
                    caption: "Pure caches — they rebuild themselves. Zero cost.",
                    tint: Theme.tierCache
                ),
                .init(
                    label: "If you rebuild",
                    value: reclaimable.items.isEmpty ? "…" : (reclaimable.totals[.regenerable] ?? 0).bytesFormatted,
                    caption: "Dependencies and build artifacts — one install away.",
                    tint: Theme.tierRegenerable
                ),
            ])
        }
    }

    /// "Since <last snapshot>: physical +X · purgeable −Y" — the ledger
    /// talking back. Only shown when a previous snapshot carries metrics.
    @ViewBuilder
    private func diffLine(_ a: DiskAccounting) -> some View {
        if let prev = previousSnapshot, let m = prev.metrics,
           let prevPhysical = m["physicalUsed"], let prevPurgeable = m["purgeable"] {
            HStack(spacing: 6) {
                Image(systemName: "clock.arrow.circlepath")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                Text("Since \(prev.date, format: .relative(presentation: .named)):")
                    .foregroundStyle(.secondary)
                Text("physical \(signed(a.physicalUsed - prevPhysical))")
                    .foregroundStyle(a.physicalUsed - prevPhysical > 0 ? Theme.tierRegenerable : Theme.tierCache)
                Text("·").foregroundStyle(.tertiary)
                Text("purgeable \(signed(a.purgeable - prevPurgeable))")
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .font(.system(size: 12))
            .monospacedDigit()
            .padding(.horizontal, 4)
        }
    }

    private func signed(_ bytes: Int64) -> String {
        bytes >= 0 ? "+\(bytes.bytesFormatted)" : "−\((-bytes).bytesFormatted)"
    }

    private func load() async {
        Task { await reclaimable.loadIfNeeded() }
        Task { await updates.checkIfNeeded() }
        glance = SystemGlance.read()
        do {
            let measured = try DiskAccounting.measure()
            accounting = measured
            previousSnapshot = await LedgerStore.shared.latestSnapshot()

            if !AppRuntime.snapshotRecorded {
                AppRuntime.snapshotRecorded = true
                await LedgerStore.shared.append(LedgerEvent(
                    kind: .snapshot,
                    title: "Disk snapshot",
                    detail: "\(measured.physicalUsed.bytesFormatted) physical · \(measured.effectiveUsed.bytesFormatted) effective · \(measured.purgeable.bytesFormatted) purgeable",
                    bytes: measured.physicalUsed,
                    metrics: [
                        "physicalUsed": measured.physicalUsed,
                        "effectiveUsed": measured.effectiveUsed,
                        "purgeable": measured.purgeable,
                    ]
                ))
            }
            WidgetBridge.export(accounting: measured, reclaimable: reclaimable.grandTotal)
        } catch {
            loadError = "Couldn't measure the boot volume: \(error.localizedDescription)"
        }
    }
}

/// Asymmetric editorial hero: the protagonist numeral left, a hairline-
/// divided metric stack right, the capacity bar spanning underneath.
private struct CapacityHero: View {
    let accounting: DiskAccounting

    var body: some View {
        HeroCard {
            VStack(alignment: .leading, spacing: 26) {
                HStack(alignment: .top, spacing: 0) {
                    // Protagonist: physical usage — the real bytes.
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 7) {
                            RoundedRectangle(cornerRadius: 1.5)
                                .fill(Theme.accent)
                                .frame(width: 3, height: 11)
                            Text("PHYSICAL — BYTES ON DISK")
                                .font(.system(size: 11, weight: .semibold))
                                .tracking(1.4)
                                .foregroundStyle(.secondary)
                        }
                        Text(accounting.physicalUsedFraction, format: .percent.precision(.fractionLength(0)))
                            .font(.system(size: 96, weight: .semibold, design: .rounded))
                            .tracking(-4)
                            .monospacedDigit()
                        Text("\(accounting.physicalUsed.bytesFormatted) of \(accounting.totalCapacity.bytesFormatted)")
                            .font(.system(size: 13))
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }

                    Spacer(minLength: 40)

                    // Metric stack: the second accounting and its parts.
                    VStack(spacing: 0) {
                        metricRow("Effective used", accounting.effectiveUsed.bytesFormatted,
                                  percent: accounting.effectiveUsedFraction, tint: Theme.purgeable)
                        Divider().overlay(Theme.hairline)
                        metricRow("Purgeable", accounting.purgeable.bytesFormatted,
                                  hint: "auto-reclaimed by macOS", tint: Theme.purgeable.opacity(0.55))
                        Divider().overlay(Theme.hairline)
                        metricRow("Strictly free", accounting.physicalFree.bytesFormatted,
                                  hint: "the df-style number", tint: .white.opacity(0.35))
                        Divider().overlay(Theme.hairline)
                        metricRow("Effectively free", (accounting.physicalFree + accounting.purgeable).bytesFormatted,
                                  hint: "what Finder calls available", tint: Theme.accent.opacity(0.7))
                    }
                    .frame(width: 300)
                    .padding(.top, 4)
                }

                VStack(alignment: .leading, spacing: 10) {
                    capacityBar
                    HStack(spacing: 22) {
                        LegendDot(color: Theme.accent, label: "Yours", detail: accounting.effectiveUsed.bytesFormatted)
                        LegendDot(color: Theme.purgeable.opacity(0.55), label: "Purgeable", detail: accounting.purgeable.bytesFormatted)
                        LegendDot(color: .white.opacity(0.22), label: "Free", detail: accounting.physicalFree.bytesFormatted)
                        Spacer()
                    }
                }
            }
        }
    }

    private func metricRow(_ label: String, _ value: String, percent: Double? = nil, hint: String? = nil, tint: Color) -> some View {
        HStack(spacing: 8) {
            Circle().fill(tint).frame(width: 6, height: 6)
            Text(label)
                .font(.system(size: 12, weight: .medium))
            Spacer()
            if let percent {
                Text(percent, format: .percent.precision(.fractionLength(0)))
                    .font(.system(size: 12, design: .rounded))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            Text(value)
                .font(.system(size: 14, weight: .semibold, design: .rounded))
                .monospacedDigit()
        }
        .padding(.vertical, 11)
        .help(hint ?? label)
    }

    private var capacityBar: some View {
        GeometryReader { geo in
            let width = geo.size.width
            let yours = width * accounting.effectiveUsedFraction
            let purgeable = width * max(0, accounting.physicalUsedFraction - accounting.effectiveUsedFraction)

            HStack(spacing: 2) {
                RoundedRectangle(cornerRadius: 5).fill(Theme.accent).frame(width: max(yours, 0))
                RoundedRectangle(cornerRadius: 5).fill(Theme.purgeable.opacity(0.45)).frame(width: max(purgeable, 0))
                RoundedRectangle(cornerRadius: 5).fill(.white.opacity(0.06))
            }
        }
        .frame(height: 12)
        .clipShape(Capsule())
    }
}
