import XCTest
@testable import ClaudeMonitor

final class OfflineHookDeployerTests: XCTestCase {
    private var home: URL!

    override func setUpWithError() throws {
        home = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("claude-monitor-offlinedeployer-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: home)
    }

    func test_installWritesScriptWithEmbeddedKeyAndMode0700() throws {
        try OfflineHookDeployer.installScript(home: home, apiKey: "SECRET-KEY-123")

        let dest = home.appendingPathComponent(".claude-monitor/offline-prowl.sh")
        XCTAssertTrue(FileManager.default.fileExists(atPath: dest.path))
        let contents = try String(contentsOf: dest)
        XCTAssertTrue(contents.contains("SECRET-KEY-123"))
        XCTAssertFalse(contents.contains("__PROWL_API_KEY__"),
                       "placeholder should be substituted out")

        let attrs = try FileManager.default.attributesOfItem(atPath: dest.path)
        let mode = (attrs[.posixPermissions] as? NSNumber)?.intValue ?? 0
        XCTAssertEqual(mode, 0o700)
    }

    func test_installOverwritesPreviousScript() throws {
        try OfflineHookDeployer.installScript(home: home, apiKey: "FIRST")
        try OfflineHookDeployer.installScript(home: home, apiKey: "SECOND")

        let dest = home.appendingPathComponent(".claude-monitor/offline-prowl.sh")
        let contents = try String(contentsOf: dest)
        XCTAssertTrue(contents.contains("SECOND"))
        XCTAssertFalse(contents.contains("FIRST"))
    }

    func test_uninstallRemovesScript() throws {
        try OfflineHookDeployer.installScript(home: home, apiKey: "X")
        try OfflineHookDeployer.uninstallScript(home: home)
        let dest = home.appendingPathComponent(".claude-monitor/offline-prowl.sh")
        XCTAssertFalse(FileManager.default.fileExists(atPath: dest.path))
    }

    func test_uninstallIsNoopWhenScriptMissing() throws {
        XCTAssertNoThrow(try OfflineHookDeployer.uninstallScript(home: home))
    }
}
