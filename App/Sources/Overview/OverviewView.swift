import SwiftUI
import ScannerKit
import RulesKit
import LedgerKit

/// Tracks once-per-launch work.
@MainActor
enum AppRuntime {
    static var snapshotRecorded = false
}

/// The honest numbers. Both accountings, side by side, always.
struct OverviewView: View {
    @State private var accounting: DiskAccounting?
    @State private var rulesCount: Int = 0
    @State private var loadError: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.sectionGap) {
                PageHeader(
                    title: "Your disk, honestly.",
                    subtitle: "Two accountings of the same volume — physical bytes, and what's effectively yours."
                )

                SetupCard()

                if let accounting {
                    CapacityHero(accounting: accounting)
                    statGrid(accounting)
                    tierLegend
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
            .padding(Theme.pagePadding)
        }
        .task { await load() }
    }

    private func statGrid(_ a: DiskAccounting) -> some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 14), count: 3), spacing: 14) {
            StatTile(
                symbol: "arrow.3.trianglepath",
                tint: Theme.purgeable,
                label: "Purgeable",
                value: a.purgeable.bytesFormatted,
                caption: "macOS reclaims this automatically the moment space runs low."
            )
            StatTile(
                symbol: "internaldrive",
                tint: Theme.accent,
                label: "Strictly free",
                value: a.physicalFree.bytesFormatted,
                caption: "Untouched space — the df-style number."
            )
            StatTile(
                symbol: "checklist",
                tint: Theme.tierCache,
                label: "Rules loaded",
                value: "\(rulesCount)",
                caption: "Allowlist-only. Anything unrecognized is your data — untouchable."
            )
        }
    }

    private var tierLegend: some View {
        Card(padding: 16) {
            HStack(spacing: 26) {
                LegendDot(color: Theme.tierCache, label: "Cache", detail: "regenerates itself")
                LegendDot(color: Theme.tierRegenerable, label: "Regenerable", detail: "costs a rebuild")
                LegendDot(color: Theme.tierData, label: "Your data", detail: "never suggested")
                Spacer()
            }
        }
    }

    private func load() async {
        do {
            let measured = try DiskAccounting.measure()
            accounting = measured
            rulesCount = try RulesRegistry.bundled().rules.count

            if !AppRuntime.snapshotRecorded {
                AppRuntime.snapshotRecorded = true
                await LedgerStore.shared.append(LedgerEvent(
                    kind: .snapshot,
                    title: "Disk snapshot",
                    detail: "\(measured.physicalUsed.bytesFormatted) physical · \(measured.effectiveUsed.bytesFormatted) effective · \(measured.purgeable.bytesFormatted) purgeable",
                    bytes: measured.physicalUsed
                ))
            }
        } catch {
            loadError = "Couldn't measure the boot volume: \(error.localizedDescription)"
        }
    }
}

/// The hero: two honest numbers over one segmented capacity bar.
private struct CapacityHero: View {
    let accounting: DiskAccounting

    var body: some View {
        HeroCard {
            VStack(alignment: .leading, spacing: 22) {
                HStack(alignment: .firstTextBaseline, spacing: 44) {
                    bigNumber(
                        label: "Physical",
                        fraction: accounting.physicalUsedFraction,
                        detail: "\(accounting.physicalUsed.bytesFormatted) on disk",
                        tint: Theme.accent
                    )
                    bigNumber(
                        label: "Effective",
                        fraction: accounting.effectiveUsedFraction,
                        detail: "\(accounting.effectiveUsed.bytesFormatted) after purgeable",
                        tint: Theme.purgeable
                    )
                    Spacer()
                    VStack(alignment: .trailing, spacing: 3) {
                        Text(accounting.totalCapacity.bytesFormatted)
                            .font(.system(.title3, design: .rounded).weight(.semibold))
                            .monospacedDigit()
                        Text("total capacity")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
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

    private func bigNumber(label: String, fraction: Double, detail: String, tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 7) {
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(tint)
                    .frame(width: 3, height: 12)
                Text(label.uppercased())
                    .font(.caption.weight(.semibold))
                    .tracking(1.2)
                    .foregroundStyle(.secondary)
            }
            Text(fraction, format: .percent.precision(.fractionLength(0)))
                .font(.system(size: 46, weight: .semibold, design: .rounded))
                .monospacedDigit()
            Text(detail)
                .font(.callout)
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
    }

    private var capacityBar: some View {
        GeometryReader { geo in
            let width = geo.size.width
            let yours = width * accounting.effectiveUsedFraction
            let purgeable = width * max(0, accounting.physicalUsedFraction - accounting.effectiveUsedFraction)

            HStack(spacing: 2) {
                RoundedRectangle(cornerRadius: 4).fill(Theme.accent).frame(width: max(yours, 0))
                RoundedRectangle(cornerRadius: 4).fill(Theme.purgeable.opacity(0.45)).frame(width: max(purgeable, 0))
                RoundedRectangle(cornerRadius: 4).fill(.white.opacity(0.07))
            }
        }
        .frame(height: 8)
        .clipShape(Capsule())
    }
}
