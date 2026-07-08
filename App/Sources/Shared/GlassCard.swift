import SwiftUI

/// The standard surface: a white card floating on the silver canvas —
/// soft diffused ambient shadow + hairline, never a harsh border.
struct Card<Content: View>: View {
    var padding: CGFloat = 20
    @ViewBuilder var content: () -> Content

    var body: some View {
        content()
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: Theme.radiusCard, style: .continuous)
                    .fill(Theme.surface1)
                    .shadow(color: .black.opacity(0.05), radius: 14, y: 5)
                    .shadow(color: .black.opacity(0.03), radius: 2, y: 1)
            )
            .overlay {
                RoundedRectangle(cornerRadius: Theme.radiusCard, style: .continuous)
                    .strokeBorder(Theme.hairline, lineWidth: 1)
            }
    }
}

/// The hero surface — double-bezel: a tinted outer tray holding the white
/// card, like a glass plate seated in a machined recess.
struct HeroCard<Content: View>: View {
    @ViewBuilder var content: () -> Content

    var body: some View {
        content()
            .padding(26)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: Theme.radiusCard, style: .continuous)
                    .fill(Theme.surface1)
                    .shadow(color: .black.opacity(0.06), radius: 18, y: 7)
            )
            .overlay {
                RoundedRectangle(cornerRadius: Theme.radiusCard, style: .continuous)
                    .strokeBorder(Theme.hairline, lineWidth: 1)
            }
            .padding(6)
            .background(
                RoundedRectangle(cornerRadius: Theme.radiusCard + 6, style: .continuous)
                    .fill(Color.black.opacity(0.025))
            )
            .overlay {
                RoundedRectangle(cornerRadius: Theme.radiusCard + 6, style: .continuous)
                    .strokeBorder(Color.black.opacity(0.04), lineWidth: 1)
            }
    }
}

/// A small icon container — saturated tint on a soft tinted field.
struct IconTile: View {
    let symbol: String
    var tint: Color? = nil
    var size: CGFloat = 30

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: size * 0.42, weight: .semibold))
            .foregroundStyle(tint ?? Theme.inkTertiary)
            .frame(width: size, height: size)
            .background(
                (tint ?? Theme.inkTertiary).opacity(0.12),
                in: RoundedRectangle(cornerRadius: size * 0.3, style: .continuous)
            )
    }
}

/// A colored dot + label, for legends.
struct LegendDot: View {
    let color: Color
    let label: String
    var detail: String? = nil

    var body: some View {
        HStack(spacing: 7) {
            Circle().fill(color).frame(width: 7, height: 7)
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
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(color.opacity(0.12), in: Capsule())
    }
}

/// The dashboard delta chip: "↗ +2.1 GB" on a tinted pill. Growth of a
/// cost metric reads warm; shrink reads green.
struct DeltaChip: View {
    let bytes: Int64
    var growthIsBad = true

    private var isUp: Bool { bytes >= 0 }
    private var tint: Color {
        if bytes == 0 { return Theme.inkTertiary }
        return (isUp && growthIsBad) || (!isUp && !growthIsBad) ? Theme.metricHeat : Theme.ok
    }

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: isUp ? "arrow.up.right" : "arrow.down.right")
                .font(.system(size: 8.5, weight: .bold))
            Text("\(isUp ? "+" : "−")\(abs(bytes).bytesFormatted)")
                .font(.system(size: 10.5, weight: .semibold))
                .monospacedDigit()
        }
        .foregroundStyle(tint)
        .padding(.horizontal, 7)
        .padding(.vertical, 3.5)
        .background(tint.opacity(0.12), in: Capsule())
    }
}

/// The reference-style arc gauge: a 270° ring with rounded caps — value
/// sweep in the metric's hue over a quiet track.
struct ArcGauge: View {
    let fraction: Double          // 0…1
    let tint: Color
    var lineWidth: CGFloat = 14
    var size: CGFloat = 140

    private let startAngle = 135.0
    private let sweep = 270.0

    var body: some View {
        ZStack {
            arc(from: 0, to: 1)
                .stroke(Theme.track, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
            arc(from: 0, to: max(0.001, min(fraction, 1)))
                .stroke(
                    AngularGradient(
                        colors: [tint.opacity(0.7), tint],
                        center: .center,
                        startAngle: .degrees(startAngle),
                        endAngle: .degrees(startAngle + sweep * max(0.001, min(fraction, 1)))
                    ),
                    style: StrokeStyle(lineWidth: lineWidth, lineCap: .round)
                )
        }
        .frame(width: size, height: size)
    }

    private func arc(from: Double, to: Double) -> Path {
        Path { p in
            p.addArc(
                center: CGPoint(x: size / 2, y: size / 2),
                radius: (size - lineWidth) / 2,
                startAngle: .degrees(startAngle + sweep * from),
                endAngle: .degrees(startAngle + sweep * to),
                clockwise: false
            )
        }
    }
}

/// A stat tile: icon, caps label, big numeral, optional delta chip.
struct StatTile: View {
    let symbol: String
    let tint: Color
    let label: String
    let value: String
    let caption: String
    var delta: Int64? = nil

    var body: some View {
        Card(padding: 18) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 9) {
                    IconTile(symbol: symbol, tint: tint, size: 26)
                    Text(label.uppercased())
                        .font(.system(size: 10.5, weight: .semibold))
                        .tracking(1.1)
                        .foregroundStyle(.secondary)
                    Spacer()
                    if let delta { DeltaChip(bytes: delta) }
                }
                Text(value)
                    .font(.system(size: 27, weight: .bold, design: .rounded))
                    .tracking(-0.5)
                    .monospacedDigit()
                Text(caption)
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.inkTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// The screen chassis: pinned header bar over a hairline; content scrolls under.
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
                        .font(.system(size: 20, weight: .bold))
                        .tracking(-0.4)
                        .lineLimit(1).truncationMode(.tail)
                    if let subtitle {
                        Text(subtitle)
                            .font(.system(size: 11.5))
                            .foregroundStyle(.secondary)
                            .lineLimit(1).truncationMode(.tail)
                    }
                }
                .layoutPriority(1)
                Spacer(minLength: 8)
                actions()
            }
            .padding(.horizontal, Theme.pagePadding)
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
                .padding(.horizontal, 12)
                .padding(.vertical, 6.5)
                .background(
                    Capsule().fill(Theme.surface1)
                        .shadow(color: .black.opacity(0.05), radius: 4, y: 2)
                )
                .overlay(Capsule().strokeBorder(Theme.hairline, lineWidth: 1))
        }
        .buttonStyle(Pressable())
        .disabled(disabled)
    }
}

/// One white card of columns divided by vertical hairlines.
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
                            Circle().fill(col.tint).frame(width: 7, height: 7)
                            Text(col.label.uppercased())
                                .font(.system(size: 10.5, weight: .semibold))
                                .tracking(1.1)
                                .foregroundStyle(.secondary)
                        }
                        Text(col.value)
                            .font(.system(size: 24, weight: .bold, design: .rounded))
                            .tracking(-0.5)
                            .monospacedDigit()
                        Text(col.caption)
                            .font(.system(size: 11))
                            .foregroundStyle(Theme.inkTertiary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(18)
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
        // The divider Rectangles are vertically greedy — pin to ideal height.
        .fixedSize(horizontal: false, vertical: true)
    }
}

/// The unified list row chassis: hover lifts to a soft tinted field.
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

/// Data as graphics: a fixed-width proportional bar.
struct SizeBar: View {
    let fraction: Double
    var tint: Color = Theme.inkTertiary.opacity(0.5)
    var width: CGFloat = 110

    var body: some View {
        ZStack(alignment: .leading) {
            Capsule().fill(Theme.track)
            Capsule()
                .fill(tint)
                .frame(width: max(width * min(fraction, 1), fraction > 0 ? 3 : 0))
        }
        .frame(width: width, height: 5)
    }
}

/// Press feedback for anything clickable.
struct Pressable: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.975 : 1)
            .opacity(configuration.isPressed ? 0.85 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}
