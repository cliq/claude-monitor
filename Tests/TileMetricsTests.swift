import XCTest
import SwiftUI
@testable import ClaudeMonitor

final class TileMetricsTests: XCTestCase {
    func test_smallMatchesSpec() {
        let m = TileMetrics.resolve(.small)
        XCTAssertEqual(m.tileSize, CGSize(width: 120, height: 64))
        XCTAssertEqual(m.padding, 6)
        XCTAssertEqual(m.gutter, 6)
        XCTAssertEqual(m.cornerRadius, 8)
        XCTAssertEqual(m.titlePointSize, 10)
        XCTAssertEqual(m.titleWeight, .semibold)
        XCTAssertEqual(m.statusPointSize, 8)
        XCTAssertEqual(m.previewPointSize, 8)
        XCTAssertEqual(m.previewWeight, .medium, "Small uses medium weight preview so white on saturated fills stays crisp")
        XCTAssertEqual(m.previewLineSpacing, 1)
        XCTAssertEqual(m.dotSize, 6)
    }

    func test_mediumMatchesSpecAndMatchesTodayDefaults() {
        let m = TileMetrics.resolve(.medium)
        XCTAssertEqual(m.tileSize, CGSize(width: 160, height: 80))
        XCTAssertEqual(m.padding, 8)
        XCTAssertEqual(m.gutter, 8)
        XCTAssertEqual(m.cornerRadius, 10)
        XCTAssertEqual(m.titlePointSize, 11)
        XCTAssertEqual(m.titleWeight, .semibold)
        XCTAssertEqual(m.statusPointSize, 9)
        XCTAssertEqual(m.previewPointSize, 9)
        XCTAssertEqual(m.previewWeight, .regular)
        XCTAssertEqual(m.previewLineSpacing, 1)
        XCTAssertEqual(m.dotSize, 8)
    }

    func test_largeMatchesSpec() {
        let m = TileMetrics.resolve(.large)
        XCTAssertEqual(m.tileSize, CGSize(width: 200, height: 104))
        XCTAssertEqual(m.padding, 10)
        XCTAssertEqual(m.gutter, 10)
        XCTAssertEqual(m.cornerRadius, 12)
        XCTAssertEqual(m.titlePointSize, 13)
        XCTAssertEqual(m.titleWeight, .semibold)
        XCTAssertEqual(m.statusPointSize, 11)
        XCTAssertEqual(m.previewPointSize, 11)
        XCTAssertEqual(m.previewWeight, .regular)
        XCTAssertEqual(m.dotSize, 10)
    }

    func test_xlargeMatchesSpec() {
        let m = TileMetrics.resolve(.xlarge)
        XCTAssertEqual(m.tileSize, CGSize(width: 240, height: 128))
        XCTAssertEqual(m.padding, 12)
        XCTAssertEqual(m.gutter, 12)
        XCTAssertEqual(m.cornerRadius, 14)
        XCTAssertEqual(m.titlePointSize, 16)
        XCTAssertEqual(m.titleWeight, .bold, "XL uses bold — 16pt semibold reads under-weighted on light tiles")
        XCTAssertEqual(m.statusPointSize, 13)
        XCTAssertEqual(m.previewPointSize, 13)
        XCTAssertEqual(m.previewWeight, .regular)
        XCTAssertEqual(m.dotSize, 12)
    }

    func test_everyTileSizeResolves() {
        // Guarantees the switch in resolve(_:) stays exhaustive if a new case is ever added.
        for size in TileSize.allCases {
            _ = TileMetrics.resolve(size)
        }
    }
}
