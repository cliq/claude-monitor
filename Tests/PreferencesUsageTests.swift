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
        XCTAssertFalse(prefs.showUsagePanel)
        XCTAssertEqual(prefs.disabledUsageAccountDirs, [])
        XCTAssertEqual(prefs.usageAccountNames, [:])
        XCTAssertEqual(prefs.usageAccountOrder, [])
    }

    func test_accountCustomizationsRoundTrip() {
        let prefs = Preferences(defaults: defaults)
        prefs.showUsagePanel = true
        prefs.disabledUsageAccountDirs = ["/h/.claudewho-b"]
        prefs.usageAccountNames = ["/h/.claudewho-a": "work"]
        prefs.usageAccountOrder = ["/h/.claudewho-b", "/h/.claudewho-a"]

        let reloaded = Preferences(defaults: defaults)
        XCTAssertTrue(reloaded.showUsagePanel)
        XCTAssertEqual(reloaded.disabledUsageAccountDirs, ["/h/.claudewho-b"])
        XCTAssertEqual(reloaded.usageAccountNames, ["/h/.claudewho-a": "work"])
        XCTAssertEqual(reloaded.usageAccountOrder, ["/h/.claudewho-b", "/h/.claudewho-a"])
    }

    func test_usagePreferencesRoundTrip() {
        let prefs = Preferences(defaults: defaults)
        prefs.usageMonitorEnabled = true
        prefs.usageBridgeEnabled = true
        prefs.usageBridgePort = 9000

        let reloaded = Preferences(defaults: defaults)
        XCTAssertTrue(reloaded.usageMonitorEnabled)
        XCTAssertTrue(reloaded.usageBridgeEnabled)
        XCTAssertEqual(reloaded.usageBridgePort, 9000)
    }

    func test_invalidStoredPortFallsBackToDefault() {
        defaults.set(0, forKey: "usageBridgePort")
        XCTAssertEqual(Preferences(defaults: defaults).usageBridgePort, 8737)

        defaults.set(70000, forKey: "usageBridgePort")
        XCTAssertEqual(Preferences(defaults: defaults).usageBridgePort, 8737)
    }
}
