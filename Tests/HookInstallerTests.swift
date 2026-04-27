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
        _ = try writeSettings("settings-with-managed-v3")
        let status = try HookInstaller.inspect(configDir: dir)
        XCTAssertEqual(status.status, .installed)
        XCTAssertEqual(status.installedVersion, HookInstaller.currentVersion)
    }

    func test_inspectReportsOutdatedForV1Fixture() throws {
        _ = try writeSettings("settings-with-managed-v1")
        let status = try HookInstaller.inspect(configDir: dir)
        XCTAssertEqual(status.status, .outdated,
                       "v1 used a schema Claude Code rejects; users should be prompted to reinstall")
        XCTAssertEqual(status.installedVersion, 1)
    }

    func test_inspectReportsOutdatedForV2Fixture() throws {
        _ = try writeSettings("settings-with-managed-v2")
        let status = try HookInstaller.inspect(configDir: dir)
        XCTAssertEqual(status.status, .outdated,
                       "v2 predates the arg-encoded managed tag; reinstall surfaces the upgrade")
        XCTAssertEqual(status.installedVersion, 2)
    }

    func test_inspectReportsOutdatedWhenSidecarKeysWereStripped() throws {
        // Real-world bug: Claude Code's settings loader re-serialized settings.json and
        // dropped the unknown `_managedBy`/`_version` keys, leaving the `hooks` blocks
        // with only `matcher` + nested `hooks[]`. Detection must still recognize these
        // entries as ours by the `.claude-monitor/hook.sh` path in the command, and flag
        // them as outdated so one-click Reinstall rewrites them with the arg-encoded tag.
        _ = try writeSettings("settings-with-stripped-metadata")
        let status = try HookInstaller.inspect(configDir: dir)
        XCTAssertEqual(status.status, .outdated)
        XCTAssertEqual(status.installedVersion, 0,
                       "no `--version=N` arg and no sidecar means we don't know the prior version")
    }

    func test_installAddsAllFiveHooksWithClaudeCodeHookSchema() throws {
        let path = try writeSettings("settings-empty")
        try HookInstaller.install(configDir: dir)
        let after = try JSONSerialization.jsonObject(with: Data(contentsOf: path)) as! [String: Any]
        let hooks = try XCTUnwrap(after["hooks"] as? [String: Any])
        XCTAssertEqual(Set(hooks.keys), ["SessionStart","UserPromptSubmit","Stop","Notification","SessionEnd"])

        // Each managed entry must be a matcher-level object carrying
        //   { _managedBy, _version, matcher, hooks: [{ type, command }] }
        // where `hooks: []` is what Claude Code's validator requires.
        for name in ["SessionStart","UserPromptSubmit","Stop","Notification","SessionEnd"] {
            let entries = try XCTUnwrap(hooks[name] as? [[String: Any]])
            XCTAssertEqual(entries.count, 1, "\(name) should have exactly one managed entry")
            let entry = entries[0]
            XCTAssertEqual(entry["_managedBy"] as? String, "claude-monitor")
            XCTAssertEqual(entry["_version"] as? Int, HookInstaller.currentVersion)
            XCTAssertEqual(entry["matcher"] as? String, "")
            let inner = try XCTUnwrap(entry["hooks"] as? [[String: Any]])
            XCTAssertEqual(inner.count, 1)
            XCTAssertEqual(inner[0]["type"] as? String, "command")
            XCTAssertEqual(inner[0]["command"] as? String,
                           "$HOME/.claude-monitor/hook.sh \(name) --managed-by=claude-monitor --version=\(HookInstaller.currentVersion)",
                           "command must carry the arg-encoded managed tag so detection survives even when sidecar keys get stripped")
        }
    }

    func test_installPreservesUserOwnedHooksAndOtherKeys() throws {
        let path = try writeSettings("settings-with-other-hooks")
        try HookInstaller.install(configDir: dir)
        let after = try JSONSerialization.jsonObject(with: Data(contentsOf: path)) as! [String: Any]
        XCTAssertEqual(after["other_key"] as? String, "preserve me")

        let hooks = try XCTUnwrap(after["hooks"] as? [String: Any])
        let start = try XCTUnwrap(hooks["SessionStart"] as? [[String: Any]])
        // One user-owned, one managed — both present side-by-side.
        XCTAssertEqual(start.count, 2)
        XCTAssertTrue(start.contains { entry in
            // User entry preserved verbatim (matcher="", inner command is echo user-owned-hook).
            (entry["_managedBy"] as? String) == nil
                && ((entry["hooks"] as? [[String: Any]])?.first?["command"] as? String) == "echo user-owned-hook"
        })
        XCTAssertTrue(start.contains { $0["_managedBy"] as? String == "claude-monitor" })

        let stop = try XCTUnwrap(hooks["Stop"] as? [[String: Any]])
        XCTAssertEqual(stop.count, 2)
        XCTAssertTrue(stop.contains { entry in
            ((entry["hooks"] as? [[String: Any]])?.first?["command"] as? String) == "custom-thing"
        })
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
        let innerCmd = (start.first?["hooks"] as? [[String: Any]])?.first?["command"] as? String
        XCTAssertEqual(innerCmd, "echo user-owned-hook")
        XCTAssertNil(hooks["UserPromptSubmit"])   // was only managed — hook key removed
    }

    func test_uninstallCleansUpLegacyV1ManagedEntries() throws {
        // A user upgrading from v1 still has the old flat-command managed entries in their
        // file. Uninstall must remove them even though they predate the current schema.
        _ = try writeSettings("settings-with-managed-v1")
        try HookInstaller.uninstall(configDir: dir)
        let after = try JSONSerialization.jsonObject(with: Data(contentsOf: dir.appendingPathComponent("settings.json"))) as! [String: Any]
        XCTAssertNil(after["hooks"], "every hook entry was managed — `hooks` object should be removed")
    }

    func test_uninstallCleansUpEntriesThatLostTheirSidecarKeys() throws {
        // Same recovery story for the stripped-metadata case: we still own these entries
        // (the command points at .claude-monitor/hook.sh) so uninstall must remove them.
        _ = try writeSettings("settings-with-stripped-metadata")
        try HookInstaller.uninstall(configDir: dir)
        let after = try JSONSerialization.jsonObject(with: Data(contentsOf: dir.appendingPathComponent("settings.json"))) as! [String: Any]
        XCTAssertNil(after["hooks"], "stripped entries should still be recognized and removed")
    }

    func test_installWritesBackupOfPreviousSettings() throws {
        let path = try writeSettings("settings-with-other-hooks")
        let originalBytes = try Data(contentsOf: path)

        try HookInstaller.install(configDir: dir)

        let backup = path.appendingPathExtension("bak")
        XCTAssertTrue(FileManager.default.fileExists(atPath: backup.path),
                      "expected settings.json.bak beside settings.json")
        let backupBytes = try Data(contentsOf: backup)
        XCTAssertEqual(backupBytes, originalBytes,
                       "backup must capture the file contents as they were before install")
    }

    func test_installOnFreshConfigDirDoesNotCreateBackup() throws {
        // No settings.json yet — there's nothing to back up.
        try HookInstaller.install(configDir: dir)
        let backup = dir.appendingPathComponent("settings.json.bak")
        XCTAssertFalse(FileManager.default.fileExists(atPath: backup.path),
                       "no backup should be created when there was no prior file")
    }

    func test_secondInstallOverwritesBackupWithLatestPreInstallState() throws {
        let path = try writeSettings("settings-empty")
        try HookInstaller.install(configDir: dir)          // first install; backup captures empty {}
        let afterFirstInstallBytes = try Data(contentsOf: path)

        try HookInstaller.install(configDir: dir)          // second install; backup should now be post-first-install state
        let backup = path.appendingPathExtension("bak")
        let backupBytes = try Data(contentsOf: backup)
        XCTAssertEqual(backupBytes, afterFirstInstallBytes,
                       "rolling backup must reflect state immediately before the most recent write")
    }

    // MARK: Offline-prowl managed entry

    func test_inspectOfflineHookReportsNotInstalledWhenAbsent() throws {
        _ = try writeSettings("settings-with-managed-v3")
        let status = try HookInstaller.inspectOfflineHook(configDir: dir)
        XCTAssertEqual(status.status, .notInstalled)
    }

    func test_inspectOfflineHookReportsInstalledWhenPresent() throws {
        _ = try writeSettings("settings-with-managed-offline-v1")
        let status = try HookInstaller.inspectOfflineHook(configDir: dir)
        XCTAssertEqual(status.status, .installed)
        XCTAssertEqual(status.installedVersion, 1)
    }

    func test_installOfflineHookLeavesMainHookIntact() throws {
        let url = try writeSettings("settings-with-managed-v3")
        try HookInstaller.installOfflineHook(configDir: dir)

        XCTAssertEqual(try HookInstaller.inspect(configDir: dir).status, .installed,
                       "main hook entry must still be detected")
        XCTAssertEqual(try HookInstaller.inspectOfflineHook(configDir: dir).status, .installed)
        // Sanity-check the file has both managed blocks for Stop.
        let json = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]
        let stop = (json?["hooks"] as? [String: Any])?["Stop"] as? [[String: Any]] ?? []
        XCTAssertEqual(stop.count, 2)
    }

    func test_uninstallOfflineHookLeavesMainHookIntact() throws {
        _ = try writeSettings("settings-with-managed-main-and-offline")
        try HookInstaller.uninstallOfflineHook(configDir: dir)

        XCTAssertEqual(try HookInstaller.inspect(configDir: dir).status, .installed)
        XCTAssertEqual(try HookInstaller.inspectOfflineHook(configDir: dir).status, .notInstalled)
    }
}
