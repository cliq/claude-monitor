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

    var hasOnboarded: Bool {
        get { defaults.bool(forKey: Self.onboardedKey) }
        set { defaults.set(newValue, forKey: Self.onboardedKey) }
    }

    static let windowFrameAutosaveName = "ClaudeMonitorDashboardWindow"
    private static let configDirsKey        = "managedConfigDirectories"
    private static let onboardedKey         = "onboarded"
    private static let tileSizeKey          = "tileSize"
    private static let paletteKey           = "paletteID"
    private static let disabledTerminalsKey = "disabledTerminals"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.managedConfigDirectoryPaths = defaults.stringArray(forKey: Self.configDirsKey) ?? []
        self.disabledTerminalBundleIDs = Set(defaults.stringArray(forKey: Self.disabledTerminalsKey) ?? [])

        // Unknown raw values → default, so a future enum change can't prevent launch.
        let rawSize    = defaults.string(forKey: Self.tileSizeKey) ?? ""
        let rawPalette = defaults.string(forKey: Self.paletteKey)  ?? ""
        self.tileSize  = TileSize(rawValue: rawSize)    ?? .medium
        self.paletteID = PaletteID(rawValue: rawPalette) ?? .vibrant
    }
}
