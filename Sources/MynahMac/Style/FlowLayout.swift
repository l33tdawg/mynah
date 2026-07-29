import SwiftUI

/// Lays subviews out left to right, wrapping onto a new line when the next one
/// would not fit.
///
/// SwiftUI has no wrapping stack, and the two usual substitutes are both worse
/// than they look. A horizontal `ScrollView` hides content behind a gesture
/// nobody knows is available — and hides it *silently*, so a list of five
/// subjects and a list of fifteen are the same picture. A `LazyVGrid` needs
/// fixed columns, which gives chips a uniform width and turns a row of labels
/// into a table.
///
/// So: a real `Layout`, which measures its subviews at their natural size and
/// only decides where they go.
struct FlowLayout: Layout {

    var spacing: CGFloat
    /// Vertical gap between wrapped lines. Defaults to `spacing`, because chips
    /// generally want the same air in both directions.
    var lineSpacing: CGFloat?

    init(spacing: CGFloat, lineSpacing: CGFloat? = nil) {
        self.spacing = spacing
        self.lineSpacing = lineSpacing
    }

    private var betweenLines: CGFloat { lineSpacing ?? spacing }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = rows(within: proposal.width ?? .infinity, subviews: subviews)
        let width = rows.map(\.width).max() ?? 0
        let height = rows.map(\.height).reduce(0, +)
            + betweenLines * CGFloat(max(0, rows.count - 1))
        return CGSize(width: width, height: height)
    }

    func placeSubviews(
        in bounds: CGRect,
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) {
        var y = bounds.minY
        for row in rows(within: bounds.width, subviews: subviews) {
            var x = bounds.minX
            for index in row.indices {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(
                    at: CGPoint(x: x, y: y),
                    anchor: .topLeading,
                    proposal: ProposedViewSize(size)
                )
                x += size.width + spacing
            }
            y += row.height + betweenLines
        }
    }

    private struct Row {
        var indices: [Int] = []
        var width: CGFloat = 0
        var height: CGFloat = 0
    }

    /// One pass, greedy. A chip wider than the whole container still gets its
    /// own line rather than being dropped — it will overflow, which is visible
    /// and fixable, where a silently omitted subject is neither.
    private func rows(within maxWidth: CGFloat, subviews: Subviews) -> [Row] {
        var rows: [Row] = []
        var current = Row()

        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            let needed = current.indices.isEmpty ? size.width : current.width + spacing + size.width
            if !current.indices.isEmpty && needed > maxWidth {
                rows.append(current)
                current = Row()
                current.indices = [index]
                current.width = size.width
                current.height = size.height
            } else {
                current.indices.append(index)
                current.width = needed
                current.height = max(current.height, size.height)
            }
        }
        if !current.indices.isEmpty { rows.append(current) }
        return rows
    }
}
