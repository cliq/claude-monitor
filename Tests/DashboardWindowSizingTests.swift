import XCTest
@testable import ClaudeMonitor

/// Medium tiles: 80pt tall, 8pt gutter and padding, so row i spans 8 + 88i ..< 88 + 88i
/// below the window's top edge.
final class DashboardWindowSizingTests: XCTestCase {
    private let metrics = TileMetrics.resolve(.medium)

    private func size(count: Int, screenHeight: CGFloat = 1000, spaceBelowTop: CGFloat) -> NSSize {
        DashboardWindow.contentSize(count: count, metrics: metrics,
                                    screenHeight: screenHeight, spaceBelowTop: spaceBelowTop)
    }

    func test_windowAtTheTopIsCappedByScreenFraction() {
        // 80% of 1000 holds 9 rows; the screen bottom alone would allow 11.
        XCTAssertEqual(size(count: 20, spaceBelowTop: 1000).height, 16 + 9 * 80 + 8 * 8)
    }

    func test_windowLowOnTheScreenWrapsBeforeHiddenTiles() {
        // A 4th row would be 65% below the bottom, so 5 tiles take 3 rows and 2 columns.
        let s = size(count: 5, spaceBelowTop: 300)
        XCTAssertEqual(s.height, 16 + 3 * 80 + 2 * 8)
        XCTAssertEqual(s.width, 16 + 2 * 160 + 8)
    }

    func test_tileExactly40PercentOffscreenStartsANewColumn() {
        // The 4th row ends 352pt below the top; 320pt of space leaves 32pt (40%) cut off.
        XCTAssertEqual(size(count: 5, spaceBelowTop: 320).height, 16 + 3 * 80 + 2 * 8)
    }

    func test_tileLessThan40PercentOffscreenStaysInTheColumn() {
        XCTAssertEqual(size(count: 5, spaceBelowTop: 321).height, 16 + 4 * 80 + 3 * 8)
    }

    func test_windowBelowTheScreenStillShowsOneRow() {
        let s = size(count: 3, spaceBelowTop: -50)
        XCTAssertEqual(s.height, 16 + 80)
        XCTAssertEqual(s.width, 16 + 3 * 160 + 2 * 8)
    }

    func test_fewTilesNeedNoMoreRowsThanTheyHave() {
        XCTAssertEqual(size(count: 2, spaceBelowTop: 1000).height, 16 + 2 * 80 + 8)
    }
}
