import SwiftUI

/// A single stacked proportional bar — used / cached / free in one strip,
/// clipped to a capsule. The honest memory breakdown in one glance.
struct SegmentBar: View {
    let segments: [(fraction: Double, color: Color)]
    var height: CGFloat = 12

    var body: some View {
        GeometryReader { geo in
            HStack(spacing: 1.5) {
                ForEach(Array(segments.enumerated()), id: \.offset) { _, seg in
                    seg.color
                        .frame(width: max(0, geo.size.width * seg.fraction - 1.5))
                }
            }
        }
        .frame(height: height)
        .clipShape(Capsule())
        .animation(.easeOut(duration: 0.4), value: segments.map(\.fraction))
    }
}

/// True masonry: measures each card and drops it into the currently-shortest
/// column, so a tall card (CPU with a process list) doesn't drag a whole row
/// down and short cards pack tight instead of leaving gaps. Column count is
/// responsive to the available width.
struct MasonryLayout: Layout {
    var minColumnWidth: CGFloat = 340
    var spacing: CGFloat = 16
    var maxColumns: Int = 3

    private func columnCount(for width: CGFloat) -> Int {
        max(1, min(maxColumns, Int((width + spacing) / (minColumnWidth + spacing))))
    }

    private func columnWidth(_ width: CGFloat, _ cols: Int) -> CGFloat {
        (width - CGFloat(cols - 1) * spacing) / CGFloat(cols)
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? minColumnWidth
        let cols = columnCount(for: width)
        let colW = columnWidth(width, cols)
        var heights = [CGFloat](repeating: 0, count: cols)
        for sv in subviews {
            let h = sv.sizeThatFits(ProposedViewSize(width: colW, height: nil)).height
            let c = shortest(heights)
            heights[c] += (heights[c] > 0 ? spacing : 0) + h
        }
        return CGSize(width: width, height: heights.max() ?? 0)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let cols = columnCount(for: bounds.width)
        let colW = columnWidth(bounds.width, cols)
        var heights = [CGFloat](repeating: 0, count: cols)
        for sv in subviews {
            let h = sv.sizeThatFits(ProposedViewSize(width: colW, height: nil)).height
            let c = shortest(heights)
            let x = bounds.minX + CGFloat(c) * (colW + spacing)
            let y = bounds.minY + heights[c] + (heights[c] > 0 ? spacing : 0)
            sv.place(at: CGPoint(x: x, y: y), anchor: .topLeading, proposal: ProposedViewSize(width: colW, height: h))
            heights[c] += (heights[c] > 0 ? spacing : 0) + h
        }
    }

    private func shortest(_ heights: [CGFloat]) -> Int {
        var idx = 0
        for i in 1..<heights.count where heights[i] < heights[idx] - 0.5 { idx = i }
        return idx
    }
}

/// A wrapping row: lays children left-to-right and flows to the next line
/// when the width runs out — so pill/chip rows never clip or crush.
struct FlowLayout: Layout {
    var spacing: CGFloat = 6
    var lineSpacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, lineHeight: CGFloat = 0, widest: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x + size.width > maxWidth, x > 0 {
                y += lineHeight + lineSpacing
                x = 0; lineHeight = 0
            }
            x += size.width + spacing
            lineHeight = max(lineHeight, size.height)
            widest = max(widest, x - spacing)
        }
        return CGSize(width: min(maxWidth, widest), height: y + lineHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let maxWidth = bounds.width
        var x: CGFloat = 0, y: CGFloat = 0, lineHeight: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x + size.width > maxWidth, x > 0 {
                y += lineHeight + lineSpacing
                x = 0; lineHeight = 0
            }
            view.place(at: CGPoint(x: bounds.minX + x, y: bounds.minY + y),
                       anchor: .topLeading, proposal: ProposedViewSize(size))
            x += size.width + spacing
            lineHeight = max(lineHeight, size.height)
        }
    }
}
