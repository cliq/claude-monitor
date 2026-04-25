// App/Settings/Preferences.swift
import Foundation
import SwiftUI

/// Central access to persisted user preferences.
final class Preferences: ObservableObject {
    private let defaults: UserDefaults

    @Published var managedConfigDirectoryPaths: [String] {
        didSet { defaults.set(managedConfigDirectoryPaths, forKey: Self.configDirsKey) }
    }

    /// Dashboard tile size preset.
    @Published var tileSize: TileSize {
        didSet { defaults.set(tileSize.rawValue, forKey: Self.tileSizeKey) }
    }

    /// Dashboard color palette preset.
    @Published var paletteID: PaletteID {
        didSet { defaults.set(paletteID.rawValue, forKey: Self.paletteKey) }
    }

    @Published var disabledTerminalBundleIDs: Set<String> {
        didSet { defaults.set(disabledTerminalBundleIDs.sorted(), forKey: Self.disabledTerminalsKey) }
    }

    /// When true (default), the floating dashboard window is shown and the
    /// menu-bar dropdown stays minimal. When false, the window is hidden and
    /// sessions render as rows inside the status-item menu.
    @Published var showDashboardWindow: Bool {
        didSet { defaults.set(showDashboardWindow, forKey: Self.showWindowKey) }
    }

    /// Last known dashboard window frame (screen coordinates). We manage this manually
    /// instead of relying on `setFrameAutosaveName`, because borderless+floating windows
    /// don't persist reliably through AppKit's built-in autosave.
    @Published var dashboardWindowFrame: NSRect? {
        didSet {
            if let frame = dashboardWindowFrame {
                defaults.set(NSStringFromRect(frame), forKey: Self.dashboardFrameKey)
            } else {
                defaults.removeObject(forKey: Self.dashboardFrameKey)
            }
        }
    }

    var hasOnboarded: Bool {
        get { defaults.bool(forKey: Self.onboardedKey) }
        set { defaults.set(newValue, forKey: Self.onboardedKey) }
    }

    private static let configDirsKey        = "managedConfigDirectories"
    private static let onboardedKey         = "onboarded"
    private static let tileSizeKey          = "tileSize"
    private static let paletteKey           = "paletteID"
    private static let disabledTerminalsKey = "disabledTerminals"
    private static let dashboardFrameKey    = "dashboardWindowFrame"
    private static let showWindowKey        = "showDashboardWindow"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.managedConfigDirectoryPaths = defaults.stringArray(forKey: Self.configDirsKey) ?? []
        self.disabledTerminalBundleIDs = Set(defaults.stringArray(forKey: Self.disabledTerminalsKey) ?? [])

        // Unknown raw values → default, so a future enum change can't prevent launch.
        let rawSize    = defaults.string(forKey: Self.tileSizeKey) ?? ""
        let rawPalette = defaults.string(forKey: Self.paletteKey)  ?? ""
        self.tileSize  = TileSize(rawValue: rawSize)    ?? .medium
        self.paletteID = PaletteID(rawValue: rawPalette) ?? .vibrant

        if let encoded = defaults.string(forKey: Self.dashboardFrameKey) {
            let rect = NSRectFromString(encoded)
            self.dashboardWindowFrame = rect.isEmpty ? nil : rect
        }

        // `object(forKey:) as? Bool` (not `bool(forKey:)`) so a missing key
        // defaults to `true` rather than `false` — preserving the historical
        // "window is visible" behavior for upgrading users.
        self.showDashboardWindow = (defaults.object(forKey: Self.showWindowKey) as? Bool) ?? true
    }
}
