import XCTest
@testable import ClaudeMonitor

final class PreferencesUsageTests: XCTestCase {
    private var defaults: UserDefaults!
    private let suite = "ClaudeMonitorPreferencesUsageTests"

    override func setUp() {
        super.setUp()
        UserDefaults().removePersistentDomain(forName: suite)
        defaults = UserDefaults(suiteName: suite)
    }

    override func tearDown() {
        UserDefaults().removePersistentDomain(forName: suite)
        defaults = nil
        super.tearDown()
    }

    func test_usagePreferencesDefaults() {
        let prefs = Preferences(defaults: defaults)
        XCTAssertFalse(prefs.usageMonitorEnabled)
        XCTAssertFalse(prefs.usageBridgeEnabled)
        XCTAssertEqual(prefs.usageBridgePort, 8737)
        XCTAssertTrue(prefs.usageBridgeMirrorsDisplay)
        XCTAssertFalse(prefs.showUsagePanel)
        XCTAssertEqual(prefs.disabledUsageAccountDirs, [])
        XCTAssertEqual(prefs.usageAccountNames, [:])
        XCTAssertEqual(prefs.usageAccountOrder, [])
        XCTAssertEqual(prefs.externalHiddenUsageAccountDirs, [])
        XCTAssertFalse(prefs.usagePanelCompact)
    }

    func test_usagePanelFrameRoundTripAndLegacySeed() {
        let prefs = Preferences(defaults: defaults)
        XCTAssertNil(prefs.usagePanelWindowFrame)
        prefs.usagePanelWindowFrame = NSRect(x: -1882, y: 1265, width: 480, height: 373)
        XCTAssertEqual(Preferences(defaults: defaults).usagePanelWindowFrame,
                       NSRect(x: -1882, y: 1265, width: 480, height: 373))
        prefs.usagePanelWindowFrame = nil
        XCTAssertNil(Preferences(defaults: defaults).usagePanelWindowFrame)

        // Upgrading from the autosave-based panel keeps the position AppKit had
        // recorded (window rect followed by the screen rect).
        defaults.set("-1882 1265 480 373 -1920 612 1920 1050 ", forKey: Preferences.legacyUsagePanelAutosaveKey)
        XCTAssertEqual(Preferences(defaults: defaults).usagePanelWindowFrame,
                       NSRect(x: -1882, y: 1265, width: 480, height: 373))
        XCTAssertNil(Preferences.parseLegacyAutosaveFrame("garbage"))
        XCTAssertNil(Preferences.parseLegacyAutosaveFrame("0 0 0 0 0 0 1920 1050"))
    }

    func test_usagePanelRestoredTopLeft() {
        let left = NSRect(x: -1920, y: 612, width: 1920, height: 1050)
        let main = NSRect(x: 0, y: 0, width: 2560, height: 1440)
        let saved = NSRect(x: -1882, y: 1265, width: 480, height: 373)
        XCTAssertNil(UsagePanelWindow.restoredTopLeft(saved: nil, screens: [main]))
        // Saved screen disconnected → nil, caller centers instead.
        XCTAssertNil(UsagePanelWindow.restoredTopLeft(saved: saved, screens: [main]))
        XCTAssertEqual(UsagePanelWindow.restoredTopLeft(saved: saved, screens: [left, main]),
                       NSPoint(x: -1882, y: 1638))
    }

    func test_accountCustomizationsRoundTrip() {
        let prefs = Preferences(defaults: defaults)
        prefs.showUsagePanel = true
        prefs.disabledUsageAccountDirs = ["/h/.claudewho-b"]
        prefs.usageAccountNames = ["/h/.claudewho-a": "work"]
        prefs.usageAccountOrder = ["/h/.claudewho-b", "/h/.claudewho-a"]
        prefs.externalHiddenUsageAccountDirs = ["/h/.claudewho-a"]
        prefs.usagePanelCompact = true

        let reloaded = Preferences(defaults: defaults)
        XCTAssertTrue(reloaded.showUsagePanel)
        XCTAssertEqual(reloaded.disabledUsageAccountDirs, ["/h/.claudewho-b"])
        XCTAssertEqual(reloaded.usageAccountNames, ["/h/.claudewho-a": "work"])
        XCTAssertEqual(reloaded.usageAccountOrder, ["/h/.claudewho-b", "/h/.claudewho-a"])
        XCTAssertEqual(reloaded.externalHiddenUsageAccountDirs, ["/h/.claudewho-a"])
        XCTAssertTrue(reloaded.usagePanelCompact)
    }

    func test_usagePreferencesRoundTrip() {
        let prefs = Preferences(defaults: defaults)
        prefs.usageMonitorEnabled = true
        prefs.usageBridgeEnabled = true
        prefs.usageBridgePort = 9000
        prefs.usageBridgeMirrorsDisplay = false

        let reloaded = Preferences(defaults: defaults)
        XCTAssertTrue(reloaded.usageMonitorEnabled)
        XCTAssertTrue(reloaded.usageBridgeEnabled)
        XCTAssertEqual(reloaded.usageBridgePort, 9000)
        XCTAssertFalse(reloaded.usageBridgeMirrorsDisplay)
    }

    func test_invalidStoredPortFallsBackToDefault() {
        defaults.set(0, forKey: "usageBridgePort")
        XCTAssertEqual(Preferences(defaults: defaults).usageBridgePort, 8737)

        defaults.set(70000, forKey: "usageBridgePort")
        XCTAssertEqual(Preferences(defaults: defaults).usageBridgePort, 8737)
    }
}
