import Foundation
import SwiftUI

/// Plain-data color with explicit channels. Used by `Palette` so tests can
/// assert on raw hex values — `SwiftUI.Color` has no RGB accessors and its
/// `==` compares semantic identity rather than components.
struct RGB: Equatable {
    let red: Double
    let green: Double
    let blue: Double
    let opacity: Double

    init(red: Double, green: Double, blue: Double, opacity: Double = 1) {
        self.red = red
        self.green = green
        self.blue = blue
        self.opacity = opacity
    }

    /// `RGB(0x3B82F6)` for easy round-trip with the spec's hex literals.
    /// Only the low 24 bits are used. The assert catches fat-fingered literals
    /// like `RGB(0xFF3B82F6)` in debug builds; release behaviour is unchanged.
    init(_ hex: UInt32, opacity: Double = 1) {
        assert(hex <= 0xFFFFFF, "RGB hex literal must fit in 24 bits, got \(String(hex, radix: 16, uppercase: true))")
        self.init(
            red:   Double((hex >> 16) & 0xFF) / 255.0,
            green: Double((hex >>  8) & 0xFF) / 255.0,
            blue:  Double( hex        & 0xFF) / 255.0,
            opacity: opacity
        )
    }

    var color: Color {
        Color(red: red, green: green, blue: blue).opacity(opacity)
    }
}
