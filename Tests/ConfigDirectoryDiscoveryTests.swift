import XCTest
@testable import ClaudeMonitor

final class ConfigDirectoryDiscoveryTests: XCTestCase {
    private var home: URL!

    override func setUpWithError() throws {
        home = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("claude-monitor-discovery-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: home)
    }

    private func makeDir(_ name: String, withSettings: Bool) throws -> URL {
        let url = home.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        if withSettings {
            try "{}".write(to: url.appendingPathComponent("settings.json"),
                           atomically: true, encoding: .utf8)
        }
        return url
    }

    func test_findsClaudeAndClaudewhoDirectories() throws {
        _ = try makeDir(".claude", withSettings: true)
        _ = try makeDir(".claudewho-work", withSettings: true)
        _ = try makeDir(".claudewho-personal", withSettings: true)
        _ = try makeDir(".unrelated", withSettings: true)        // not matched
        _ = try makeDir(".claudewho-broken", withSettings: false) // no settings -> skipped

        let found = ConfigDirectoryDiscovery.scan(home: home).map(\.lastPathComponent).sorted()
        XCTAssertEqual(found, [".claude", ".claudewho-personal", ".claudewho-work"])
    }

    func test_returnsEmptyWhenNoCandidates() throws {
        let found = ConfigDirectoryDiscovery.scan(home: home)
        XCTAssertEqual(found, [])
    }

    func test_scanPiFindsAgentDirectoryWithConfig() throws {
        let agent = home.appendingPathComponent(".pi/agent")
        try FileManager.default.createDirectory(at: agent, withIntermediateDirectories: true)
        XCTAssertEqual(ConfigDirectoryDiscovery.scanPi(home: home), [],
                       "an empty agent dir is not a pi install")

        try "{}".write(to: agent.appendingPathComponent("settings.json"), atomically: true, encoding: .utf8)
        XCTAssertEqual(ConfigDirectoryDiscovery.scanPi(home: home).map(\.lastPathComponent), ["agent"])
        XCTAssertFalse(ConfigDirectoryDiscovery.scan(home: home).contains { $0.path.contains(".pi") })
    }

    func test_scanPiReturnsEmptyWithoutPi() {
        XCTAssertEqual(ConfigDirectoryDiscovery.scanPi(home: home), [])
    }
}
