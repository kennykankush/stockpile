import SwiftUI
import RulesKit

/// Stockpile's design tokens — the Linear/Raycast school: an opaque
/// near-black surface ladder for depth (no shadows, no glows), hairline
/// borders, typography doing the drama, color doing almost nothing.
enum Theme {
    // MARK: Surface ladder (opaque — depth without shadows)
    static let canvas = Color(red: 0.024, green: 0.027, blue: 0.033)      // ~#060709
    static let surface1 = Color(red: 0.055, green: 0.059, blue: 0.071)    // cards
    static let surface2 = Color(red: 0.080, green: 0.084, blue: 0.102)    // hover / controls
    static let surface3 = Color(red: 0.104, green: 0.110, blue: 0.133)    // selected / lifted

    // MARK: Lines
    static let hairline = Color.white.opacity(0.07)
    static let hairlineStrong = Color.white.opacity(0.14)
    /// Linear's signature: a faint top-edge light on lifted panels.
    static let edgeHighlight = Color.white.opacity(0.10)

    // MARK: Color — semantic only, accent near-nowhere
    static let accent = Color(red: 0.39, green: 0.88, blue: 0.76)
    static let purgeable = Color(red: 0.48, green: 0.62, blue: 0.86)
    static let tierCache = Color(red: 0.45, green: 0.83, blue: 0.55)
    static let tierRegenerable = Color(red: 0.93, green: 0.72, blue: 0.38)
    static let tierData = Color(red: 0.91, green: 0.47, blue: 0.51)

    // MARK: Metrics
    static let radiusCard: CGFloat = 14
    static let radiusRow: CGFloat = 9
    static let pagePadding: CGFloat = 36
    static let sectionGap: CGFloat = 28
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

/// Flat opaque canvas. No blooms, no gradients — surfaces and type carry
/// the interface. (Glass lives in the chrome layer: the sidebar.)
struct Backdrop: View {
    var body: some View {
        Theme.canvas.ignoresSafeArea()
    }
}

/// Page header: display-weight title with tight tracking, quiet subtitle.
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

/// Small-caps section label — tracked out, quiet.
struct SectionLabel: View {
    let text: String
    var trailing: String? = nil

    var body: some View {
        HStack {
            Text(text.uppercased())
                .font(.system(size: 11, weight: .semibold))
                .tracking(1.4)
                .foregroundStyle(.secondary)
            Spacer()
            if let trailing {
                Text(trailing)
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 2)
    }
}
