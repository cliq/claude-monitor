import XCTest
import AppKit
@testable import ClaudeMonitor

final class SessionStateColorTests: XCTestCase {
    func testEachStateMapsToDistinctColor() {
        let states: [SessionState] = [.needsYou, .waiting, .working, .finished]
        let hexes = states.map { SessionStateColor.nsColor(for: $0).hexString }
        XCTAssertEqual(Set(hexes).count, states.count,
                       "Each session state must map to a distinct color (got \(hexes))")
    }

    func testKnownHexValues() {
        XCTAssertEqual(SessionStateColor.nsColor(for: .needsYou).hexString, "#EF4444")
        XCTAssertEqual(SessionStateColor.nsColor(for: .waiting).hexString,  "#F59E0B")
        XCTAssertEqual(SessionStateColor.nsColor(for: .working).hexString,  "#3B82F6")
        XCTAssertEqual(SessionStateColor.nsColor(for: .finished).hexString, "#6B7280")
    }
}

private extension NSColor {
    var hexString: String {
        // The literal NSColors are in sRGB; convert to be safe.
        let c = usingColorSpace(.sRGB) ?? self
        let r = Int(round(c.redComponent   * 255))
        let g = Int(round(c.greenComponent * 255))
        let b = Int(round(c.blueComponent  * 255))
        return String(format: "#%02X%02X%02X", r, g, b)
    }
}
