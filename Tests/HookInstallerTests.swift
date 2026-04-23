// Tests/HookInstallerTests.swift
import XCTest
@testable import ClaudeMonitor

final class HookInstallerTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("claude-monitor-installer-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    private func loadFixture(_ name: String) throws -> Data {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: name, withExtension: "json"),
                                "missing fixture \(name).json")
        return try Data(contentsOf: url)
    }

    private func writeSettings(_ fixture: String) throws -> URL {
        let data = try loadFixture(fixture)
        let url = dir.appendingPathComponent("settings.json")
        try data.write(to: url)
        return url
    }

    func test_inspectReportsNotInstalledForEmptySettings() throws {
        _ = try writeSettings("settings-empty")
        let status = try HookInstaller.inspect(configDir: dir)
        XCTAssertEqual(status.status, .notInstalled)
        XCTAssertEqual(status.installedVersion, 0)
    }

    func test_inspectReportsInstalledForCurrentVersionFixture() throws {
        _ = try writeSettings("settings-with-managed-v1")
        let status = try HookInstaller.inspect(configDir: dir)
        XCTAssertEqual(status.status, .installed)
        XCTAssertEqual(status.installedVersion, HookInstaller.currentVersion)
    }

    func test_installAddsAllFiveHooksToEmptySettings() throws {
        let path = try writeSettings("settings-empty")
        try HookInstaller.install(configDir: dir)
        let after = try JSONSerialization.jsonObject(with: Data(contentsOf: path)) as! [String: Any]
        let hooks = try XCTUnwrap(after["hooks"] as? [String: Any])
        XCTAssertEqual(Set(hooks.keys), ["SessionStart","UserPromptSubmit","Stop","Notification","SessionEnd"])
        let start = try XCTUnwrap(hooks["SessionStart"] as? [[String: Any]])
        XCTAssertEqual(start.first?["_managedBy"] as? String, "claude-monitor")
        XCTAssertEqual(start.first?["_version"] as? Int, HookInstaller.currentVersion)
    }

    func test_installPreservesUserOwnedHooksAndOtherKeys() throws {
        let path = try writeSettings("settings-with-other-hooks")
        try HookInstaller.install(configDir: dir)
        let after = try JSONSerialization.jsonObject(with: Data(contentsOf: path)) as! [String: Any]
        XCTAssertEqual(after["other_key"] as? String, "preserve me")

        let hooks = try XCTUnwrap(after["hooks"] as? [String: Any])
        let start = try XCTUnwrap(hooks["SessionStart"] as? [[String: Any]])
        // One user-owned, one managed — both present.
        XCTAssertEqual(start.count, 2)
        XCTAssertTrue(start.contains { $0["command"] as? String == "echo user-owned-hook" })
        XCTAssertTrue(start.contains { $0["_managedBy"] as? String == "claude-monitor" })

        let stop = try XCTUnwrap(hooks["Stop"] as? [[String: Any]])
        XCTAssertEqual(stop.count, 2)
        XCTAssertTrue(stop.contains { $0["command"] as? String == "custom-thing" })
    }

    func test_installIsIdempotent() throws {
        _ = try writeSettings("settings-empty")
        try HookInstaller.install(configDir: dir)
        try HookInstaller.install(configDir: dir)
        let after = try JSONSerialization.jsonObject(with: Data(contentsOf: dir.appendingPathComponent("settings.json"))) as! [String: Any]
        let hooks = try XCTUnwrap(after["hooks"] as? [String: Any])
        for key in ["SessionStart","UserPromptSubmit","Stop","Notification","SessionEnd"] {
            let entries = hooks[key] as! [[String: Any]]
            XCTAssertEqual(entries.count, 1, "\(key) should have exactly one managed entry")
        }
    }

    func test_uninstallRemovesManagedBlocksOnly() throws {
        let path = try writeSettings("settings-with-other-hooks")
        try HookInstaller.install(configDir: dir)
        try HookInstaller.uninstall(configDir: dir)
        let after = try JSONSerialization.jsonObject(with: Data(contentsOf: path)) as! [String: Any]
        let hooks = try XCTUnwrap(after["hooks"] as? [String: Any])

        let start = try XCTUnwrap(hooks["SessionStart"] as? [[String: Any]])
        XCTAssertEqual(start.count, 1)
        XCTAssertEqual(start.first?["command"] as? String, "echo user-owned-hook")
        XCTAssertNil(hooks["UserPromptSubmit"])   // was only managed — hook key removed
    }
}
