import SwiftUI
import RulesKit

/// Fleetwatch's design tokens — the expensive-light dashboard treatment:
/// silver canvas, floating white cards on soft diffused shadows, saturated
/// per-metric accents, big rounded numerals. Color *means* something here
/// and is allowed to show it.
enum Theme {
    // MARK: Canvas & surfaces (light ladder)
    static let canvas = Color(red: 0.965, green: 0.969, blue: 0.976)     // #F6F7F9
    static let surface1 = Color.white                                    // cards
    static let surface2 = Color(red: 0.933, green: 0.941, blue: 0.957)   // controls / hover
    static let surface3 = Color(red: 0.894, green: 0.906, blue: 0.929)   // selected

    // MARK: Lines & ink
    static let hairline = Color.black.opacity(0.06)
    static let hairlineStrong = Color.black.opacity(0.12)
    static let inkTertiary = Color(red: 0.58, green: 0.62, blue: 0.68)
    /// Neutral bar-track behind proportional fills.
    static let track = Color.black.opacity(0.06)

    // MARK: Metric palette — saturated, each organ owns a hue
    static let accent = Color(red: 0.24, green: 0.39, blue: 0.87)        // brand blue
    static let metricDisk = Color(red: 0.23, green: 0.51, blue: 0.96)    // blue
    static let metricMemory = Color(red: 0.55, green: 0.36, blue: 0.96)  // purple
    static let metricHeat = Color(red: 0.96, green: 0.62, blue: 0.11)    // orange
    static let metricCPU = Color(red: 0.08, green: 0.72, blue: 0.65)     // teal
    static let metricGPU = Color(red: 0.42, green: 0.69, blue: 0.13)     // nvidia green
    static let ok = Color(red: 0.06, green: 0.73, blue: 0.51)            // green
    static let danger = Color(red: 0.94, green: 0.27, blue: 0.27)        // red

    // Legacy tier/purgeable names, re-valued for light.
    static let purgeable = Color(red: 0.38, green: 0.65, blue: 0.98)
    static let tierCache = ok
    static let tierRegenerable = metricHeat
    static let tierData = danger

    // MARK: Metrics
    static let radiusCard: CGFloat = 18
    static let radiusRow: CGFloat = 10
    static let pagePadding: CGFloat = 28
    static let sectionGap: CGFloat = 22

    /// Severity color for a 0…1 usage fraction.
    static func severity(_ f: Double) -> Color {
        f > 0.9 ? danger : f > 0.75 ? metricHeat : ok
    }

    /// Temperature (°C) → color: cool reads calm, hot reads alarming.
    static func tempColor(_ c: Double) -> Color {
        c >= 85 ? danger : c >= 72 ? metricHeat : c >= 55 ? metricCPU : ok
    }
}

extension Tier {
    var color: Color {
        switch self {
        case .cache: Theme.tierCache
        case .regenerable: Theme.tierRegenerable
        }
    }

    var badgeLabel: String {
        switch self {
        case .cache: "Cache"
        case .regenerable: "Regenerable"
        }
    }
}

extension Int64 {
    var bytesFormatted: String {
        self.formatted(.byteCount(style: .file))
    }
}

/// Silver-grey canvas — the cards float above it on soft shadows.
struct Backdrop: View {
    var body: some View {
        Theme.canvas.ignoresSafeArea()
    }
}

/// Page header (legacy — most screens use Screen's pinned bar).
struct PageHeader: View {
    let title: String
    let subtitle: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.system(size: 30, weight: .bold))
                .tracking(-0.9)
            Text(subtitle)
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
        }
    }
}

/// Small-caps section label.
struct SectionLabel: View {
    let text: String
    var trailing: String? = nil

    var body: some View {
        HStack {
            Text(text.uppercased())
                .font(.system(size: 11, weight: .semibold))
                .tracking(1.2)
                .foregroundStyle(.secondary)
            Spacer()
            if let trailing {
                Text(trailing)
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.inkTertiary)
            }
        }
        .padding(.horizontal, 2)
    }
}
