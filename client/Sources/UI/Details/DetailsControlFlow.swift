import SwiftUI

/// Preserve each action's readable size and source order instead of squeezing
/// the entire row into a narrow hero.
struct DetailsControlFlow: Layout {
    var spacing: CGFloat = 12
    var rowSpacing: CGFloat = 10

    private func arrangement(width: CGFloat, subviews: Subviews) -> (sizes: [CGSize], origins: [CGPoint], height: CGFloat) {
        var sizes: [CGSize] = []
        var origins: [CGPoint] = []
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        for view in subviews {
            let ideal = view.sizeThatFits(.unspecified)
            let size = view.sizeThatFits(.init(width: min(width, ideal.width), height: nil))
            if x > 0, x + size.width > width {
                x = 0
                y += rowHeight + rowSpacing
                rowHeight = 0
            }
            sizes.append(size)
            origins.append(CGPoint(x: x, y: y))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
        return (sizes, origins, y + rowHeight)
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? subviews.reduce(CGFloat(0)) { $0 + $1.sizeThatFits(.unspecified).width + spacing }
        return CGSize(width: width, height: arrangement(width: width, subviews: subviews).height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let result = arrangement(width: bounds.width, subviews: subviews)
        for index in subviews.indices {
            let origin = result.origins[index]
            let size = result.sizes[index]
            subviews[index].place(at: CGPoint(x: bounds.minX + origin.x, y: bounds.minY + origin.y),
                                  proposal: .init(width: size.width, height: size.height))
        }
    }
}
