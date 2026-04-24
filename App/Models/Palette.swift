import Foundation
import SwiftUI

/// A complete set of tile colors plus the text/dot color used on top of them.
/// Source of truth: design spec §4. Lookup table lives in `Palette.resolve(_:)`.
///
/// Naming split vs the spec: the spec's `color(for:) -> Color` is implemented
/// here as two methods — `background(for:) -> RGB` is the testable
/// channel-level API (used by `PaletteTests`), and `backgroundColor(for:) -> Color`
/// is the SwiftUI view-layer convenience. Similarly, `text: RGB` is the storage
/// and `textColor: Color` is the SwiftUI shim.
struct Palette: Equatable {
    let id: PaletteID
    let displayName: String
    let working: RGB
    let waiting: RGB
    let needsYou: RGB
    let finished: RGB
    /// Color for both tile text AND the status dot (§4 of the spec).
    let text: RGB

    func background(for state: SessionState) -> RGB {
        switch state {
        case .working:  return working
        case .waiting:  return waiting
        case .needsYou: return needsYou
        case .finished: return finished
        }
    }

    /// SwiftUI-side convenience. Prefer `background(for:)` in tests.
    func backgroundColor(for state: SessionState) -> Color { background(for: state).color }
    var textColor: Color { text.color }
}

extension Palette {
    static func resolve(_ id: PaletteID) -> Palette {
        switch id {
        case .vibrant:
            return Palette(
                id: .vibrant, displayName: "Vibrant",
                working:  RGB(0x3B82F6),
                waiting:  RGB(0xF59E0B),
                needsYou: RGB(0xEF4444),
                finished: RGB(0x6B7280),
                text:     RGB(0xFFFFFF)
            )
        case .pastel:
            return Palette(
                id: .pastel, displayName: "Pastel",
                working:  RGB(0xBFD7EA),
                waiting:  RGB(0xF4D5A0),
                needsYou: RGB(0xF3B6B6),
                finished: RGB(0xD6CFC5),
                text:     RGB(0x1A1A1A, opacity: 0.9)
            )
        case .highContrast:
            return Palette(
                id: .highContrast, displayName: "High Contrast",
                working:  RGB(0x0A4D8C),
                waiting:  RGB(0x8C4A00),
                needsYou: RGB(0xB80000),
                finished: RGB(0x1F2937),
                text:     RGB(0xFFFFFF)
            )
        case .mono:
            return Palette(
                id: .mono, displayName: "Monochrome",
                working:  RGB(0x111827),
                waiting:  RGB(0x4B5563),
                needsYou: RGB(0xDC2626),
                finished: RGB(0x9CA3AF),
                text:     RGB(0xFFFFFF)
            )
        case .sunset:
            return Palette(
                id: .sunset, displayName: "Sunset",
                working:  RGB(0xEA580C),
                waiting:  RGB(0xA16207),
                needsYou: RGB(0xBE123C),
                finished: RGB(0x78716C),
                text:     RGB(0xFFFFFF)
            )
        }
    }

    static var all: [Palette] { PaletteID.allCases.map(resolve) }
}
