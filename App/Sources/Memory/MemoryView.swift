import SwiftUI
import MemoryKit
import HonestKit
import LedgerKit

@MainActor
@Observable
final class MemoryModel {
    var reading: MemoryReading?

    func load() async {
        let r = MemoryMonitor().read()
        reading = r
        if let r, !AppRuntime.memoryRecorded {
            AppRuntime.memoryRecorded = true
            await LedgerStore.shared.append(LedgerEvent(
                kind: .snapshot,
                title: "Memory snapshot",
                detail: "\(r.used.bytesFormatted) in use · \(r.available.bytesFormatted) available · \(r.pressureHeadline.lowercased())",
                bytes: r.used,
                metrics: ["memUsed": r.used, "memAvailable": r.available, "memCached": r.cached]
            ))
        }
    }
}

/// Memory: the purgeable lesson applied to RAM. "Used" as other tools show it
/// counts cached files that vanish the instant you need the space — so the
/// honest number is smaller, and the scary one is a lie of omission.
struct MemoryView: View {
    @State private var model = MemoryModel()

    var body: some View {
        Screen(
            title: "Memory",
            subtitle: "Your RAM, honestly — cached files aren't \"used,\" they're evictable."
        ) {
            if let r = model.reading {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        hero(r)
                        breakdown(r)
                    }
                    .padding(24)
                }
            } else {
                ProgressView("Reading memory…").frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task { await model.load() }
    }

    private func hero(_ r: MemoryReading) -> some View {
        HeroCard {
            HStack(alignment: .top, spacing: 0) {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 7) {
                        RoundedRectangle(cornerRadius: 1.5).fill(color(r.pressure)).frame(width: 3, height: 11)
                        Text("HONEST — GENUINELY IN USE")
                            .font(.system(size: 11, weight: .semibold)).tracking(1.4).foregroundStyle(.secondary)
                    }
                    Text(r.usedFraction, format: .percent.precision(.fractionLength(0)))
                        .font(.system(size: 82, weight: .semibold, design: .rounded)).tracking(-3.2).monospacedDigit()
                    Text("\(r.used.bytesFormatted) of \(r.total.bytesFormatted) · \(r.pressureHeadline)")
                        .font(.system(size: 13)).foregroundStyle(.secondary).monospacedDigit()
                }
                Spacer(minLength: 40)
                VStack(spacing: 0) {
                    metricRow("Naive \"used\"", (r.total - r.free).bytesFormatted, hint: "what other tools show", tint: .white.opacity(0.35))
                    Divider().overlay(Theme.hairline)
                    metricRow("Cached files", r.cached.bytesFormatted, hint: "evictable — the difference", tint: Theme.purgeable.opacity(0.55))
                    Divider().overlay(Theme.hairline)
                    metricRow("Available", r.available.bytesFormatted, hint: "free + cached", tint: Theme.accent.opacity(0.7))
                }
                .frame(width: 300).padding(.top, 4)
            }
        }
    }

    private func breakdown(_ r: MemoryReading) -> some View {
        StatStrip(columns: [
            .init(label: "App memory", value: r.app.bytesFormatted, caption: "Anonymous memory your apps hold.", tint: Theme.accent),
            .init(label: "Wired", value: r.wired.bytesFormatted, caption: "Locked by the kernel — can't move.", tint: Theme.tierRegenerable),
            .init(label: "Compressed", value: r.compressed.bytesFormatted, caption: "Squeezed to avoid swapping to disk.", tint: Theme.purgeable),
            .init(label: "Free", value: r.free.bytesFormatted, caption: "Untouched, immediately usable.", tint: Theme.tierCache),
        ])
    }

    private func metricRow(_ label: String, _ value: String, hint: String, tint: Color) -> some View {
        HStack(spacing: 8) {
            Circle().fill(tint).frame(width: 6, height: 6)
            VStack(alignment: .leading, spacing: 0) {
                Text(label).font(.system(size: 12, weight: .medium))
                Text(hint).font(.system(size: 10.5)).foregroundStyle(.tertiary)
            }
            Spacer()
            Text(value).font(.system(size: 14, weight: .semibold, design: .rounded)).monospacedDigit()
        }
        .padding(.vertical, 9)
    }

    private func color(_ p: PressureLevel) -> Color {
        switch p {
        case .nominal: Theme.tierCache
        case .fair: Theme.accent
        case .serious: Theme.tierRegenerable
        case .critical: Theme.tierData
        }
    }
}
