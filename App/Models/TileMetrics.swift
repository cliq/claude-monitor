import Foundation
import SwiftUI

/// Geometry + typography for one tile-size preset. Source of truth: design spec §3.
/// Font sizes are stored as point values + weight so tests can assert on plain
/// numbers; `TileView` builds `Font.system(size:weight:)` at render time.
struct TileMetrics: Equatable {
    let tileSize: CGSize
    let padding: CGFloat
    let gutter: CGFloat
    let cornerRadius: CGFloat

    let titlePointSize: CGFloat
    let titleWeight: Font.Weight

    let statusPointSize: CGFloat

    let previewPointSize: CGFloat
    let previewWeight: Font.Weight
    let previewLineSpacing: CGFloat

    let dotSize: CGFloat
}

extension TileMetrics {
    /// The single table that turns a `TileSize` preset into concrete geometry.
    /// Keep every row here in sync with the spec — any change is visible to the user.
    static func resolve(_ size: TileSize) -> TileMetrics {
        switch size {
        case .small:
            return TileMetrics(
                tileSize: CGSize(width: 120, height: 64),
                padding: 6, gutter: 6, cornerRadius: 8,
                titlePointSize: 10, titleWeight: .semibold,
                statusPointSize: 8,
                previewPointSize: 8, previewWeight: .medium, previewLineSpacing: 1,
                dotSize: 6
            )
        case .medium:
            return TileMetrics(
                tileSize: CGSize(width: 160, height: 80),
                padding: 8, gutter: 8, cornerRadius: 10,
                titlePointSize: 11, titleWeight: .semibold,
                statusPointSize: 9,
                previewPointSize: 9, previewWeight: .regular, previewLineSpacing: 1,
                dotSize: 8
            )
        case .large:
            return TileMetrics(
                tileSize: CGSize(width: 200, height: 104),
                padding: 10, gutter: 10, cornerRadius: 12,
                titlePointSize: 13, titleWeight: .semibold,
                statusPointSize: 11,
                previewPointSize: 11, previewWeight: .regular, previewLineSpacing: 1,
                dotSize: 10
            )
        case .xlarge:
            return TileMetrics(
                tileSize: CGSize(width: 240, height: 128),
                padding: 12, gutter: 12, cornerRadius: 14,
                titlePointSize: 16, titleWeight: .bold,
                statusPointSize: 13,
                previewPointSize: 13, previewWeight: .regular, previewLineSpacing: 1,
                dotSize: 12
            )
        }
    }
}
