import SwiftUI

/// The standard surface: one step up the ladder, hairline edge with a faint
/// top-light — depth without a single shadow. Content never gets glass;
/// glass belongs to the chrome (the sidebar has it natively).
struct Card<Content: View>: View {
    var padding: CGFloat = 22
    @ViewBuilder var content: () -> Content

    var body: some View {
        content()
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.surface1, in: RoundedRectangle(cornerRadius: Theme.radiusCard, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: Theme.radiusCard, style: .continuous)
                    .strokeBorder(
                        LinearGradient(
                            colors: [Theme.edgeHighlight, Theme.hairline],
                            startPoint: .top,
                            endPoint: .bottom
                        ),
                        lineWidth: 1
                    )
            }
    }
}

/// The hero surface: same ladder, more presence — larger radius and padding,
/// a slightly stronger top light. Opaque, like everything content.
struct HeroCard<Content: View>: View {
    @ViewBuilder var content: () -> Content

    var body: some View {
        content()
            .padding(30)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.surface1, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .strokeBorder(
                        LinearGradient(
                            colors: [.white.opacity(0.13), Theme.hairline],
                            startPoint: .top,
                            endPoint: .bottom
                        ),
                        lineWidth: 1
                    )
            }
    }
}

/// A small icon container. Neutral by default — one step up the ladder with
/// a secondary glyph. Pass a tint only when the color *means* something.
struct IconTile: View {
    let symbol: String
    var tint: Color? = nil
    var size: CGFloat = 30

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: size * 0.42, weight: .medium))
            .foregroundStyle(tint ?? Color.secondary)
            .frame(width: size, height: size)
            .background(
                tint.map { $0.opacity(0.10) } ?? Theme.surface2,
                in: RoundedRectangle(cornerRadius: size * 0.27, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: size * 0.27, style: .continuous)
                    .strokeBorder(tint?.opacity(0.2) ?? Theme.hairline, lineWidth: 1)
            }
    }
}

/// A colored dot + label, for legends.
struct LegendDot: View {
    let color: Color
    let label: String
    var detail: String? = nil

    var body: some View {
        HStack(spacing: 7) {
            Circle().fill(color).frame(width: 6, height: 6)
            Text(label)
                .font(.system(size: 12, weight: .medium))
            if let detail {
                Text(detail)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
        }
    }
}

/// Compact capsule badge, tier- or source-tinted.
struct TierBadge: View {
    let label: String
    let color: Color

    var body: some View {
        Text(label)
            .font(.system(size: 10, weight: .semibold))
            .tracking(0.2)
            .foregroundStyle(color)
            .padding(.horizontal, 7)
            .padding(.vertical, 2.5)
            .background(color.opacity(0.10), in: Capsule())
            .overlay(Capsule().strokeBorder(color.opacity(0.22), lineWidth: 1))
    }
}

/// A stat tile: tracked-out caps label, big rounded numeral, quiet caption.
struct StatTile: View {
    let symbol: String
    let tint: Color
    let label: String
    let value: String
    let caption: String

    var body: some View {
        Card(padding: 20) {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 9) {
                    IconTile(symbol: symbol, tint: tint, size: 24)
                    Text(label.uppercased())
                        .font(.system(size: 11, weight: .semibold))
                        .tracking(1.4)
                        .foregroundStyle(.secondary)
                }
                Text(value)
                    .font(.system(size: 28, weight: .semibold, design: .rounded))
                    .tracking(-0.5)
                    .monospacedDigit()
                Text(caption)
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// The unified list row chassis: bare on the canvas, hover lifts one surface
/// step. Used by Descend, Apps, and any large list.
struct HoverRow<Content: View>: View {
    @ViewBuilder var content: () -> Content
    @State private var hovering = false

    var body: some View {
        content()
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(
                hovering ? Theme.surface2 : .clear,
                in: RoundedRectangle(cornerRadius: Theme.radiusRow, style: .continuous)
            )
            .contentShape(RoundedRectangle(cornerRadius: Theme.radiusRow, style: .continuous))
            .onHover { hovering = $0 }
    }
}
