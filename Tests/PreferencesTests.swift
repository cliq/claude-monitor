import XCTest
@testable import ClaudeMonitor

final class PreferencesTests: XCTestCase {
    private var defaults: UserDefaults!
    private let suite = "ClaudeMonitorPreferencesTests"

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

    func test_disabledTerminalBundleIDs_defaultsToEmpty() {
        let prefs = Preferences(defaults: defaults)
        XCTAssertEqual(prefs.disabledTerminalBundleIDs, [])
    }

    func test_disabledTerminalBundleIDs_roundTrips() {
        let prefs = Preferences(defaults: defaults)
        prefs.disabledTerminalBundleIDs = ["com.googlecode.iterm2"]
        let reloaded = Preferences(defaults: defaults)
        XCTAssertEqual(reloaded.disabledTerminalBundleIDs, ["com.googlecode.iterm2"])
    }

    func test_disabledTerminalBundleIDs_cleared() {
        let prefs = Preferences(defaults: defaults)
        prefs.disabledTerminalBundleIDs = ["com.apple.Terminal", "com.googlecode.iterm2"]
        prefs.disabledTerminalBundleIDs = []
        let reloaded = Preferences(defaults: defaults)
        XCTAssertEqual(reloaded.disabledTerminalBundleIDs, [])
    }
}
