import Foundation

/// Identifies one of the five built-in color palettes. Each case resolves to a
/// `Palette` via `Palette.resolve(_:)`. Persisted in `UserDefaults` via `Preferences`.
enum PaletteID: String, Codable, CaseIterable {
    case vibrant
    case pastel
    case highContrast
    case mono
    case sunset
}
