import XCTest
import SwiftUI
@testable import ClaudeMonitor

final class PaletteTests: XCTestCase {
    // MARK: Hex round-trip

    func test_rgbHexInitMatchesExpectedChannels() {
        let c = RGB(0x3B82F6)
        XCTAssertEqual(c.red,   Double(0x3B) / 255.0, accuracy: 1e-9)
        XCTAssertEqual(c.green, Double(0x82) / 255.0, accuracy: 1e-9)
        XCTAssertEqual(c.blue,  Double(0xF6) / 255.0, accuracy: 1e-9)
        XCTAssertEqual(c.opacity, 1.0)
    }

    func test_rgbHexInitWithOpacity() {
        let c = RGB(0x1A1A1A, opacity: 0.9)
        XCTAssertEqual(c.opacity, 0.9)
    }

    // MARK: Palette table

    func test_vibrantMatchesSpec() {
        let p = Palette.resolve(.vibrant)
        XCTAssertEqual(p.id, .vibrant)
        XCTAssertEqual(p.working,  RGB(0x3B82F6))
        XCTAssertEqual(p.waiting,  RGB(0xF59E0B))
        XCTAssertEqual(p.needsYou, RGB(0xEF4444))
        XCTAssertEqual(p.finished, RGB(0x6B7280))
        XCTAssertEqual(p.text,     RGB(0xFFFFFF))
    }

    func test_pastelMatchesSpecAndHasDarkText() {
        let p = Palette.resolve(.pastel)
        XCTAssertEqual(p.working,  RGB(0xBFD7EA))
        XCTAssertEqual(p.waiting,  RGB(0xF4D5A0))
        XCTAssertEqual(p.needsYou, RGB(0xF3B6B6))
        XCTAssertEqual(p.finished, RGB(0xD6CFC5))
        XCTAssertEqual(p.text,     RGB(0x1A1A1A, opacity: 0.9),
                       "Pastel is the only palette with dark text")
    }

    func test_highContrastMatchesSpec() {
        let p = Palette.resolve(.highContrast)
        XCTAssertEqual(p.working,  RGB(0x0A4D8C))
        XCTAssertEqual(p.waiting,  RGB(0x8C4A00))
        XCTAssertEqual(p.needsYou, RGB(0xB80000))
        XCTAssertEqual(p.finished, RGB(0x1F2937))
        XCTAssertEqual(p.text,     RGB(0xFFFFFF))
    }

    func test_monoMatchesSpec() {
        let p = Palette.resolve(.mono)
        XCTAssertEqual(p.working,  RGB(0x111827))
        XCTAssertEqual(p.waiting,  RGB(0x4B5563))
        XCTAssertEqual(p.needsYou, RGB(0xDC2626))
        XCTAssertEqual(p.finished, RGB(0x9CA3AF))
        XCTAssertEqual(p.text,     RGB(0xFFFFFF))
    }

    func test_sunsetMatchesSpec() {
        let p = Palette.resolve(.sunset)
        XCTAssertEqual(p.working,  RGB(0xEA580C))
        XCTAssertEqual(p.waiting,  RGB(0xA16207))
        XCTAssertEqual(p.needsYou, RGB(0xBE123C))
        XCTAssertEqual(p.finished, RGB(0x78716C))
        XCTAssertEqual(p.text,     RGB(0xFFFFFF))
    }

    // MARK: color(for:) dispatch

    func test_colorForStateMapsCorrectly() {
        let p = Palette.resolve(.vibrant)
        // Compare via RGB since SwiftUI.Color equality is semantic.
        XCTAssertEqual(p.background(for: .working),  p.working)
        XCTAssertEqual(p.background(for: .waiting),  p.waiting)
        XCTAssertEqual(p.background(for: .needsYou), p.needsYou)
        XCTAssertEqual(p.background(for: .finished), p.finished)
    }

    // MARK: Exhaustiveness

    func test_everyPaletteIDResolves() {
        for id in PaletteID.allCases {
            XCTAssertEqual(Palette.resolve(id).id, id)
        }
    }

    func test_paletteAllExposesEveryCase() {
        XCTAssertEqual(Palette.all.map(\.id), PaletteID.allCases)
    }

    // MARK: WCAG contrast

    /// High Contrast exists specifically as the a11y-compliant option. It is the
    /// single palette we hard-enforce at WCAG AA (4.5:1 for normal text). The
    /// other four palettes are deliberate stylistic choices using industry-common
    /// mid-saturation hues (Tailwind 500s etc.) that don't clear 4.5:1 with white
    /// text — see `test_contrastRatiosForAllPalettesForHumanReview` below.
    func test_highContrastMeetsWCAG_AA_ForEveryBackground() {
        let minimumContrast = 4.5
        let palette = Palette.resolve(.highContrast)
        for state in SessionState.allCases {
            let ratio = WCAG.contrastRatio(palette.text, palette.background(for: state))
            XCTAssertGreaterThanOrEqual(
                ratio, minimumContrast,
                "High Contrast must meet AA for a11y: text on \(state) is only \(String(format: "%.2f", ratio)):1"
            )
        }
    }

    /// Non-asserting — prints the contrast ratio for every (palette, state) pair
    /// into the test log so regressions are visible during review without failing
    /// builds. The other four palettes make aesthetic tradeoffs the user accepted.
    func test_contrastRatiosForAllPalettesForHumanReview() {
        for palette in Palette.all {
            for state in SessionState.allCases {
                let ratio = WCAG.contrastRatio(palette.text, palette.background(for: state))
                print("[contrast] \(palette.id) · \(state): \(String(format: "%.2f", ratio)):1")
            }
        }
    }
}

// MARK: - Test-local WCAG helper

/// WCAG 2.1 relative-luminance / contrast formulas, in a test-only namespace so
/// the production module stays free of un-exercised math.
/// Reference: https://www.w3.org/TR/WCAG21/#dfn-relative-luminance
enum WCAG {
    static func relativeLuminance(_ c: RGB) -> Double {
        func channel(_ v: Double) -> Double {
            return v <= 0.03928 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4)
        }
        // Premultiply by opacity against white (the app doesn't render palettes over
        // variable backgrounds — tile fills are opaque on a transparent window).
        let r = channel(c.red   * c.opacity + (1 - c.opacity))
        let g = channel(c.green * c.opacity + (1 - c.opacity))
        let b = channel(c.blue  * c.opacity + (1 - c.opacity))
        return 0.2126 * r + 0.7152 * g + 0.0722 * b
    }

    static func contrastRatio(_ a: RGB, _ b: RGB) -> Double {
        let la = relativeLuminance(a)
        let lb = relativeLuminance(b)
        let (lighter, darker) = la > lb ? (la, lb) : (lb, la)
        return (lighter + 0.05) / (darker + 0.05)
    }
}
