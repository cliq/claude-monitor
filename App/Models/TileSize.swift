import Foundation

/// Discrete tile size presets. Each case maps to a hand-tuned `TileMetrics` row —
/// see `TileMetrics.resolve(_:)`. Persisted in `UserDefaults` via `Preferences`.
enum TileSize: String, Codable, CaseIterable {
    case small
    case medium
    case large
    case xlarge

    /// Human-facing name used by the segmented picker in Settings.
    var displayName: String {
        switch self {
        case .small:  return "Small"
        case .medium: return "Medium"
        case .large:  return "Large"
        case .xlarge: return "Extra Large"
        }
    }
}
