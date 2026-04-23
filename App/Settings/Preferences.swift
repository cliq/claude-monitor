// App/Settings/Preferences.swift
import Foundation
import SwiftUI

/// Central access to persisted user preferences.
final class Preferences: ObservableObject {
    private let defaults: UserDefaults

    @Published var managedConfigDirectoryPaths: [String] {
        didSet { defaults.set(managedConfigDirectoryPaths, forKey: Self.configDirsKey) }
    }

    @Published var manualTileOrder: [String] {
        didSet { defaults.set(manualTileOrder, forKey: Self.tileOrderKey) }
    }

    @Published var disabledTerminalBundleIDs: Set<String> {
        didSet { defaults.set(Array(disabledTerminalBundleIDs), forKey: Self.disabledTerminalsKey) }
    }

    var hasOnboarded: Bool {
        get { defaults.bool(forKey: Self.onboardedKey) }
        set { defaults.set(newValue, forKey: Self.onboardedKey) }
    }

    static let windowFrameAutosaveName = "ClaudeMonitorDashboardWindow"
    private static let configDirsKey = "managedConfigDirectories"
    private static let tileOrderKey = "manualTileOrder"
    private static let onboardedKey = "onboarded"
    private static let disabledTerminalsKey = "disabledTerminals"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.managedConfigDirectoryPaths = defaults.stringArray(forKey: Self.configDirsKey) ?? []
        self.manualTileOrder = defaults.stringArray(forKey: Self.tileOrderKey) ?? []
        self.disabledTerminalBundleIDs = Set(defaults.stringArray(forKey: Self.disabledTerminalsKey) ?? [])
    }
}
