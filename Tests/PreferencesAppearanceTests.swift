import XCTest
@testable import ClaudeMonitor

final class PreferencesAppearanceTests: XCTestCase {
    /// Each test gets a fresh, isolated UserDefaults so they don't stomp on
    /// the real app's preferences or each other.
    private func makeDefaults() -> UserDefaults {
        let suite = "claude-monitor-prefs-tests-\(UUID().uuidString)"
        let d = UserDefaults(suiteName: suite)!
        d.removePersistentDomain(forName: suite)
        return d
    }

    func test_defaultsAreMediumAndVibrant() {
        let prefs = Preferences(defaults: makeDefaults())
        XCTAssertEqual(prefs.tileSize, .medium)
        XCTAssertEqual(prefs.paletteID, .vibrant)
    }

    func test_tileSizeRoundTripsThroughUserDefaults() {
        let defaults = makeDefaults()
        let a = Preferences(defaults: defaults)
        a.tileSize = .large

        let b = Preferences(defaults: defaults)
        XCTAssertEqual(b.tileSize, .large)
    }

    func test_paletteIDRoundTripsThroughUserDefaults() {
        let defaults = makeDefaults()
        let a = Preferences(defaults: defaults)
        a.paletteID = .sunset

        let b = Preferences(defaults: defaults)
        XCTAssertEqual(b.paletteID, .sunset)
    }

    func test_unknownTileSizeRawValueFallsBackToMedium() {
        let defaults = makeDefaults()
        defaults.set("gargantuan", forKey: "tileSize")

        let prefs = Preferences(defaults: defaults)
        XCTAssertEqual(prefs.tileSize, .medium)
    }

    func test_unknownPaletteIDRawValueFallsBackToVibrant() {
        let defaults = makeDefaults()
        defaults.set("retroChic", forKey: "paletteID")

        let prefs = Preferences(defaults: defaults)
        XCTAssertEqual(prefs.paletteID, .vibrant)
    }
}
