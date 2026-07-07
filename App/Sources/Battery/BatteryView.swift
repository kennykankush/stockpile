import SwiftUI
import BatteryKit

@MainActor
@Observable
final class BatteryModel {
    var reading: BatteryReading?
    var checked = false

    func load() {
        reading = BatteryMonitor().read()
        checked = true
    }
}

/// Battery: the number Apple buries. "100%" is charge; health is how much of
/// its original capacity the cell still holds — that's the honest story.
struct BatteryView: View {
    @State private var model = BatteryModel()

    var body: some View {
        Screen(
            title: "Battery",
            subtitle: "Charge is what they show you. Health is what they don't."
        ) {
            Group {
                if let b = model.reading {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 16) {
                            hero(b)
                            stats(b)
                            Spacer(minLength: 0)
                        }
                        .padding(24)
                    }
                } else if model.checked {
                    VStack(spacing: 10) {
                        Image(systemName: "bolt.slash").font(.system(size: 40, weight: .light)).foregroundStyle(.tertiary)
                        Text("No battery").font(.system(.title3, design: .rounded).weight(.semibold))
                        Text("This is a desktop Mac — nothing to report here.")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
        .task { model.load() }
    }

    private func hero(_ b: BatteryReading) -> some View {
        HeroCard {
            HStack(alignment: .top, spacing: 0) {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 7) {
                        RoundedRectangle(cornerRadius: 1.5).fill(healthColor(b)).frame(width: 3, height: 11)
                        Text("HEALTH — CAPACITY REMAINING")
                            .font(.system(size: 11, weight: .semibold)).tracking(1.4).foregroundStyle(.secondary)
                    }
                    Text("\(b.healthPercent)%")
                        .font(.system(size: 82, weight: .semibold, design: .rounded)).tracking(-3.2)
                        .foregroundStyle(healthColor(b)).monospacedDigit()
                    Text("\(b.healthHeadline) · holds \(b.maxCapacity) of \(b.designCapacity) mAh it shipped with")
                        .font(.system(size: 13)).foregroundStyle(.secondary).monospacedDigit()
                }
                Spacer(minLength: 40)
                VStack(spacing: 0) {
                    metricRow("Charge now", "\(b.charge)%", hint: b.isCharging ? "charging" : (b.onACPower ? "on power" : "on battery"), tint: Theme.tierCache)
                    Divider().overlay(Theme.hairline)
                    metricRow("Cycle count", "\(b.cycleCount)", hint: "full charge-discharges", tint: Theme.accent.opacity(0.7))
                }
                .frame(width: 300).padding(.top, 4)
            }
        }
    }

    private func stats(_ b: BatteryReading) -> some View {
        StatStrip(columns: [
            .init(label: "Design capacity", value: "\(b.designCapacity) mAh", caption: "What it held brand new.", tint: .white.opacity(0.4)),
            .init(label: "Full capacity now", value: "\(b.maxCapacity) mAh", caption: "What a full charge holds today.", tint: Theme.accent),
            .init(label: "Cycles", value: "\(b.cycleCount)", caption: "Apple rates most cells to ~1000.", tint: Theme.tierRegenerable),
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

    private func healthColor(_ b: BatteryReading) -> Color {
        switch b.healthPercent {
        case 90...: Theme.tierCache
        case 80..<90: Theme.accent
        case 70..<80: Theme.tierRegenerable
        default: Theme.tierData
        }
    }
}
