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

/// The screen chassis: a pinned header bar (title left, actions right) over
/// a full-width hairline; content scrolls underneath. Every section uses it.
struct Screen<Actions: View, Content: View>: View {
    let title: String
    var subtitle: String? = nil
    @ViewBuilder var actions: () -> Actions
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.system(size: 19, weight: .semibold))
                        .tracking(-0.4)
                    if let subtitle {
                        Text(subtitle)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
                actions()
            }
            .padding(.horizontal, 28)
            .padding(.top, 18)
            .padding(.bottom, 14)

            Divider().overlay(Theme.hairline)

            content()
        }
    }
}

extension Screen where Actions == EmptyView {
    init(title: String, subtitle: String? = nil, @ViewBuilder content: @escaping () -> Content) {
        self.init(title: title, subtitle: subtitle, actions: { EmptyView() }, content: content)
    }
}

/// A quiet pill button for header-bar actions.
struct BarButton: View {
    let label: String
    let symbol: String
    var disabled = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label(label, systemImage: symbol)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 11)
                .padding(.vertical, 6)
                .background(Theme.surface2, in: Capsule())
                .overlay(Capsule().strokeBorder(Theme.hairline, lineWidth: 1))
        }
        .buttonStyle(Pressable())
        .disabled(disabled)
    }
}

/// A single card of columns divided by vertical hairlines — the Linear
/// "stat strip" that replaces a row of floating tiles.
struct StatStrip: View {
    struct Column: Identifiable {
        var id: String { label }
        let label: String
        let value: String
        let caption: String
        let tint: Color
    }

    let columns: [Column]

    var body: some View {
        Card(padding: 0) {
            HStack(spacing: 0) {
                ForEach(Array(columns.enumerated()), id: \.element.id) { index, col in
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(spacing: 6) {
                            Circle().fill(col.tint).frame(width: 6, height: 6)
                            Text(col.label.uppercased())
                                .font(.system(size: 10.5, weight: .semibold))
                                .tracking(1.3)
                                .foregroundStyle(.secondary)
                        }
                        Text(col.value)
                            .font(.system(size: 25, weight: .semibold, design: .rounded))
                            .tracking(-0.5)
                            .monospacedDigit()
                        Text(col.caption)
                            .font(.system(size: 11))
                            .foregroundStyle(.tertiary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(20)
                    .frame(maxWidth: .infinity, alignment: .leading)

                    if index < columns.count - 1 {
                        Rectangle()
                            .fill(Theme.hairline)
                            .frame(width: 1)
                            .padding(.vertical, 14)
                    }
                }
            }
        }
    }
}

/// The unified list row chassis: bare on the canvas, hover lifts one surface
/// step. Content receives the hover state so rows can reveal detail on
/// demand instead of captioning everything permanently.
struct HoverRow<Content: View>: View {
    @ViewBuilder var content: (Bool) -> Content
    @State private var hovering = false

    var body: some View {
        content(hovering)
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(
                hovering ? Theme.surface2 : .clear,
                in: RoundedRectangle(cornerRadius: Theme.radiusRow, style: .continuous)
            )
            .contentShape(RoundedRectangle(cornerRadius: Theme.radiusRow, style: .continuous))
            .onHover { hovering = $0 }
    }
}

/// Data as graphics: a fixed-width proportional bar — the row-level
/// visualization that turns lists into instruments.
struct SizeBar: View {
    let fraction: Double
    var tint: Color = .white.opacity(0.30)
    var width: CGFloat = 110

    var body: some View {
        ZStack(alignment: .leading) {
            Capsule().fill(Theme.surface2)
            Capsule()
                .fill(tint)
                .frame(width: max(width * min(fraction, 1), fraction > 0 ? 3 : 0))
        }
        .frame(width: width, height: 4)
    }
}

/// Press feedback for anything clickable — the interface confirming it
/// heard you. Subtle scale, fast ease-out, exactly once per press.
struct Pressable: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.975 : 1)
            .opacity(configuration.isPressed ? 0.85 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}
