import SwiftUI

/// Vertical-first flow layout. Fills column 0 top-to-bottom, then column 1, etc.
/// Implements both a `positions(tileCount:containerHeight:)` helper for unit testing
/// and the SwiftUI `Layout` protocol for live rendering.
struct VerticalFirstGridLayout: Layout {
    let tileSize: CGSize
    let gutter: CGFloat
    let padding: CGFloat

    init(tileSize: CGSize = CGSize(width: 160, height: 80),
         gutter: CGFloat = 8,
         padding: CGFloat = 8) {
        self.tileSize = tileSize
        self.gutter = gutter
        self.padding = padding
    }

    // MARK: Pure helpers (unit-testable)

    func tilesPerColumn(containerHeight: CGFloat) -> Int {
        // SwiftUI occasionally proposes `.infinity` during measurement passes (e.g. while a sheet animates).
        // `Int(floor(.infinity))` traps, so clamp to something finite before converting.
        guard containerHeight.isFinite, containerHeight > 0 else { return 1 }
        let usable = containerHeight - 2 * padding
        let slot = tileSize.height + gutter
        let fit = Int(floor((usable + gutter) / slot))  // +gutter because last tile has no trailing gutter
        return max(1, fit)
    }

    func positions(tileCount: Int, containerHeight: CGFloat) -> [CGPoint] {
        let perCol = tilesPerColumn(containerHeight: containerHeight)
        return (0..<tileCount).map { i in
            let col = i / perCol
            let row = i % perCol
            let x = padding + CGFloat(col) * (tileSize.width + gutter)
            let y = padding + CGFloat(row) * (tileSize.height + gutter)
            return CGPoint(x: x, y: y)
        }
    }

    func requiredSize(tileCount: Int, containerHeight: CGFloat) -> CGSize {
        let perCol = tilesPerColumn(containerHeight: containerHeight)
        let cols = Int(ceil(Double(tileCount) / Double(perCol)))
        let width = 2 * padding + CGFloat(cols) * tileSize.width + CGFloat(max(0, cols - 1)) * gutter
        let height = containerHeight
        return CGSize(width: width, height: height)
    }

    // MARK: SwiftUI Layout conformance

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let proposed = proposal.height ?? 600
        let containerHeight = proposed.isFinite ? proposed : 600
        return requiredSize(tileCount: subviews.count, containerHeight: containerHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let positions = positions(tileCount: subviews.count, containerHeight: bounds.height)
        for (i, subview) in subviews.enumerated() {
            let p = positions[i]
            subview.place(at: CGPoint(x: bounds.minX + p.x, y: bounds.minY + p.y),
                          proposal: ProposedViewSize(tileSize))
        }
    }
}
