// App/Settings/Preferences.swift
import Foundation
import SwiftUI

/// Central access to persisted user preferences.
final class Preferences: ObservableObject {
    private let defaults: UserDefaults

    @Published var managedConfigDirectoryPaths: [String] {
        didSet { defaults.set(managedConfigDirectoryPaths, forKey: Self.configDirsKey) }
    }

    /// Codex config directories (e.g. ~/.codex) whose hooks.json Claude Monitor manages.
    @Published var managedCodexDirectoryPaths: [String] {
        didSet { defaults.set(managedCodexDirectoryPaths, forKey: Self.codexDirsKey) }
    }

    /// When true (default), tiles and menu rows are labeled with their agent
    /// provider — but only while `multipleProvidersConfigured` (a single-agent
    /// setup needs no labels).
    @Published var showProviderBadges: Bool {
        didSet { defaults.set(showProviderBadges, forKey: Self.showProviderBadgesKey) }
    }

    /// True when directories for more than one agent provider are managed.
    var multipleProvidersConfigured: Bool {
        !managedConfigDirectoryPaths.isEmpty && !managedCodexDirectoryPaths.isEmpty
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

    /// Master toggle for Prowl push notifications.
    @Published var prowlEnabled: Bool {
        didSet { defaults.set(prowlEnabled, forKey: Self.prowlEnabledKey) }
    }

    /// When true, the offline shell hook is also installed alongside Prowl.
    @Published var prowlOfflineHookEnabled: Bool {
        didSet { defaults.set(prowlOfflineHookEnabled, forKey: Self.prowlOfflineKey) }
    }

    /// When true (default), check GitHub Releases for a newer version at launch
    /// and once a day. The check only surfaces a menu item — nothing downloads.
    @Published var updateCheckEnabled: Bool {
        didSet { defaults.set(updateCheckEnabled, forKey: Self.updateCheckKey) }
    }

    /// Master toggle for polling Anthropic's usage-limits endpoint for each
    /// discovered Claude Code account.
    @Published var usageMonitorEnabled: Bool {
        didSet { defaults.set(usageMonitorEnabled, forKey: Self.usageMonitorKey) }
    }

    /// When true (and usage monitoring is on), serve the usage snapshot over
    /// HTTP on the LAN for external displays (the ESP32 desk panel).
    @Published var usageBridgeEnabled: Bool {
        didSet { defaults.set(usageBridgeEnabled, forKey: Self.usageBridgeKey) }
    }

    /// TCP port for the usage bridge server.
    @Published var usageBridgePort: Int {
        didSet { defaults.set(usageBridgePort, forKey: Self.usageBridgePortKey) }
    }

    /// When true (default), `/display` mirrors this Mac's screen power state so
    /// external displays sleep with the Mac. When false, it always reports "on".
    @Published var usageBridgeMirrorsDisplay: Bool {
        didSet { defaults.set(usageBridgeMirrorsDisplay, forKey: Self.usageBridgeMirrorsDisplayKey) }
    }

    /// Whether the floating usage panel is shown. Gated on `usageMonitorEnabled`;
    /// toggled from the menu bar and by the panel's close button.
    @Published var showUsagePanel: Bool {
        didSet { defaults.set(showUsagePanel, forKey: Self.showUsagePanelKey) }
    }

    /// Config-dir paths excluded from usage polling. Disabled-list semantics:
    /// the default empty set opts every discovered account in.
    @Published var disabledUsageAccountDirs: Set<String> {
        didSet { defaults.set(disabledUsageAccountDirs.sorted(), forKey: Self.disabledUsageAccountsKey) }
    }

    /// Custom display names for usage accounts, keyed by config-dir path.
    /// Missing/blank entries fall back to the name derived from the dir name.
    @Published var usageAccountNames: [String: String] {
        didSet { defaults.set(usageAccountNames, forKey: Self.usageAccountNamesKey) }
    }

    /// Preferred usage-account order as config-dir paths. Dirs not listed here
    /// (newly discovered logins) are appended after the known ones.
    @Published var usageAccountOrder: [String] {
        didSet { defaults.set(usageAccountOrder, forKey: Self.usageAccountOrderKey) }
    }

    /// The app build (`CFBundleVersion`) we last refreshed the on-disk hooks for.
    /// Drives the "refresh hooks once per app update" check in `AppDelegate`.
    @Published var lastHookRefreshBuild: String? {
        didSet {
            if let build = lastHookRefreshBuild {
                defaults.set(build, forKey: Self.lastHookRefreshBuildKey)
            } else {
                defaults.removeObject(forKey: Self.lastHookRefreshBuildKey)
            }
        }
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
    private static let codexDirsKey         = "managedCodexDirectories"
    private static let showProviderBadgesKey = "showProviderBadges"
    private static let onboardedKey         = "onboarded"
    private static let tileSizeKey          = "tileSize"
    private static let paletteKey           = "paletteID"
    private static let disabledTerminalsKey = "disabledTerminals"
    private static let dashboardFrameKey    = "dashboardWindowFrame"
    private static let showWindowKey        = "showDashboardWindow"
    private static let prowlEnabledKey      = "prowlEnabled"
    private static let prowlOfflineKey      = "prowlOfflineHookEnabled"
    private static let lastHookRefreshBuildKey = "lastHookRefreshBuild"
    private static let updateCheckKey       = "updateCheckEnabled"
    private static let usageMonitorKey      = "usageMonitorEnabled"
    private static let usageBridgeKey       = "usageBridgeEnabled"
    private static let usageBridgePortKey   = "usageBridgePort"
    private static let usageBridgeMirrorsDisplayKey = "usageBridgeMirrorsDisplay"
    private static let showUsagePanelKey    = "showUsagePanel"
    private static let disabledUsageAccountsKey = "disabledUsageAccountDirs"
    private static let usageAccountNamesKey = "usageAccountNames"
    private static let usageAccountOrderKey = "usageAccountOrder"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.managedConfigDirectoryPaths = defaults.stringArray(forKey: Self.configDirsKey) ?? []
        self.managedCodexDirectoryPaths = defaults.stringArray(forKey: Self.codexDirsKey) ?? []
        // Missing key defaults to true — badges appear as soon as a second provider is configured.
        self.showProviderBadges = (defaults.object(forKey: Self.showProviderBadgesKey) as? Bool) ?? true
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

        // Missing key defaults to true — update checks are on unless opted out.
        self.updateCheckEnabled = (defaults.object(forKey: Self.updateCheckKey) as? Bool) ?? true
        self.usageMonitorEnabled = defaults.bool(forKey: Self.usageMonitorKey)
        self.usageBridgeEnabled = defaults.bool(forKey: Self.usageBridgeKey)
        let storedPort = defaults.integer(forKey: Self.usageBridgePortKey)
        self.usageBridgePort = (1...65535).contains(storedPort) ? storedPort : Int(UsageBridgeServer.defaultPort)
        // Missing key defaults to true — mirroring is the historical behavior.
        self.usageBridgeMirrorsDisplay = (defaults.object(forKey: Self.usageBridgeMirrorsDisplayKey) as? Bool) ?? true
        self.showUsagePanel = defaults.bool(forKey: Self.showUsagePanelKey)
        self.disabledUsageAccountDirs = Set(defaults.stringArray(forKey: Self.disabledUsageAccountsKey) ?? [])
        self.usageAccountNames = (defaults.dictionary(forKey: Self.usageAccountNamesKey) as? [String: String]) ?? [:]
        self.usageAccountOrder = defaults.stringArray(forKey: Self.usageAccountOrderKey) ?? []

        self.prowlEnabled = defaults.bool(forKey: Self.prowlEnabledKey)
        self.prowlOfflineHookEnabled = defaults.bool(forKey: Self.prowlOfflineKey)
        self.lastHookRefreshBuild = defaults.string(forKey: Self.lastHookRefreshBuildKey)
    }
}
