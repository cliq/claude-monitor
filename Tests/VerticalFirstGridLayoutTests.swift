import XCTest
@testable import ClaudeMonitor

final class VerticalFirstGridLayoutTests: XCTestCase {
    func test_singleColumnWhenAllTilesFitVertically() {
        // height=400 - padding(16) = 384; each tile slot is 80+8 = 88; floor(384/88) = 4 tiles per column
        let layout = VerticalFirstGridLayout(tileSize: CGSize(width: 160, height: 80), gutter: 8, padding: 8)
        let positions = layout.positions(tileCount: 4, containerHeight: 400)
        XCTAssertEqual(positions.map(\.x), [8, 8, 8, 8])
        XCTAssertEqual(positions.map(\.y), [8, 96, 184, 272])
    }

    func test_wrapsToSecondColumnWhenFirstIsFull() {
        let layout = VerticalFirstGridLayout(tileSize: CGSize(width: 160, height: 80), gutter: 8, padding: 8)
        let positions = layout.positions(tileCount: 5, containerHeight: 400)
        // 4 tiles in column 0 at x=8, 1 tile in column 1 at x = 8 + 160 + 8 = 176
        XCTAssertEqual(positions[0].x, 8)
        XCTAssertEqual(positions[3].x, 8)
        XCTAssertEqual(positions[4].x, 176)
        XCTAssertEqual(positions[4].y, 8)
    }

    func test_rejectsZeroColumnHeightGracefullyBySingleColumn() {
        // Container too short for even one tile — fall back to one-per-column.
        let layout = VerticalFirstGridLayout(tileSize: CGSize(width: 160, height: 80), gutter: 8, padding: 8)
        let positions = layout.positions(tileCount: 3, containerHeight: 40)
        XCTAssertEqual(positions.count, 3)
        // Each tile gets its own column.
        XCTAssertEqual(positions.map(\.x), [8, 176, 344])
    }

    func test_infiniteContainerHeightDoesNotTrap() {
        // SwiftUI proposes `.infinity` during some measurement passes (e.g. while a sheet animates).
        // The layout must not trap in `Int(floor(...))`.
        let layout = VerticalFirstGridLayout(tileSize: CGSize(width: 160, height: 80), gutter: 8, padding: 8)
        let positions = layout.positions(tileCount: 3, containerHeight: .infinity)
        XCTAssertEqual(positions.count, 3)
    }

    func test_totalSizeReportsRequiredWidth() {
        let layout = VerticalFirstGridLayout(tileSize: CGSize(width: 160, height: 80), gutter: 8, padding: 8)
        let size = layout.requiredSize(tileCount: 5, containerHeight: 400)
        XCTAssertEqual(size.width, 8 + 160 + 8 + 160 + 8, "2 columns of 160 plus padding/gutter")
    }
}
