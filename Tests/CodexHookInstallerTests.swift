// Tests/CodexHookInstallerTests.swift
import XCTest
@testable import ClaudeMonitor

final class CodexHookInstallerTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("claude-monitor-codex-installer-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    private var hooksURL: URL { dir.appendingPathComponent("hooks.json") }

    private func loadHooksJson() throws -> [String: Any] {
        let data = try Data(contentsOf: hooksURL)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func writeFixture(_ name: String) throws {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: name, withExtension: "json"),
                                "missing fixture \(name).json")
        try Data(contentsOf: url).write(to: hooksURL)
    }

    private func managedEntries(in json: [String: Any], event: String) -> [[String: Any]] {
        let hooks = (json["hooks"] as? [String: Any]) ?? [:]
        let entries = (hooks[event] as? [[String: Any]]) ?? []
        return entries.filter { entry in
            let inner = (entry["hooks"] as? [[String: Any]]) ?? []
            let cmd = inner.first?["command"] as? String ?? ""
            return cmd.contains(".claude-monitor/codex-hook.sh")
        }
    }

    func test_inspectReportsNotInstalledWhenNoHooksFile() throws {
        let status = try HookInstaller.inspectCodexHook(configDir: dir)
        XCTAssertEqual(status.status, .notInstalled)
    }

    func test_installCreatesHooksFileWithAllEvents() throws {
        try HookInstaller.installCodexHook(configDir: dir)
        let json = try loadHooksJson()

        for event in ["SessionStart", "UserPromptSubmit", "Stop", "PermissionRequest", "SessionEnd"] {
            let managed = managedEntries(in: json, event: event)
            XCTAssertEqual(managed.count, 1, "expected one managed entry for \(event)")
            let inner = try XCTUnwrap((managed[0]["hooks"] as? [[String: Any]])?.first)
            let cmd = try XCTUnwrap(inner["command"] as? String)
            XCTAssertTrue(cmd.contains("$HOME/.claude-monitor/codex-hook.sh \(event)"))
            XCTAssertTrue(cmd.contains("--managed-by=claude-monitor"))
            XCTAssertTrue(cmd.contains("--version=\(HookInstaller.codexCurrentVersion)"))
        }
        XCTAssertEqual(try HookInstaller.inspectCodexHook(configDir: dir).status, .installed)
    }

    func test_installWritesCodexEntryShape() throws {
        try HookInstaller.installCodexHook(configDir: dir)
        let json = try loadHooksJson()
        let entry = try XCTUnwrap(managedEntries(in: json, event: "SessionStart").first)

        // Codex entries stay schema-minimal: no matcher, no sidecar tag keys —
        // the arg-encoded command marker is the only ownership signal.
        XCTAssertNil(entry["matcher"])
        XCTAssertNil(entry["_managedBy"])
        XCTAssertNil(entry["_version"])
    }

    func test_installPinsSessionEndTimeoutInsideCodexBudget() throws {
        try HookInstaller.installCodexHook(configDir: dir)
        let json = try loadHooksJson()

        let sessionEnd = try XCTUnwrap(managedEntries(in: json, event: "SessionEnd").first)
        let inner = try XCTUnwrap((sessionEnd["hooks"] as? [[String: Any]])?.first)
        XCTAssertEqual(inner["timeout"] as? Int, 3,
                       "SessionEnd hooks default to a 1s timeout in Codex; the entry must pin the 3s max")

        let stop = try XCTUnwrap(managedEntries(in: json, event: "Stop").first)
        let stopInner = try XCTUnwrap((stop["hooks"] as? [[String: Any]])?.first)
        XCTAssertNil(stopInner["timeout"], "only SessionEnd needs an explicit timeout")
    }

    func test_installPreservesForeignEntries() throws {
        try writeFixture("codex-hooks-with-foreign-entries")
        try HookInstaller.installCodexHook(configDir: dir)
        let json = try loadHooksJson()
        let hooks = try XCTUnwrap(json["hooks"] as? [String: Any])

        for event in ["SessionStart", "PermissionRequest"] {
            let entries = try XCTUnwrap(hooks[event] as? [[String: Any]])
            let foreign = entries.filter { entry in
                let inner = (entry["hooks"] as? [[String: Any]]) ?? []
                return (inner.first?["command"] as? String ?? "").contains(".orca/")
            }
            XCTAssertEqual(foreign.count, 1, "foreign \(event) entry must survive install")
        }
    }

    func test_installIsIdempotent() throws {
        try HookInstaller.installCodexHook(configDir: dir)
        try HookInstaller.installCodexHook(configDir: dir)
        let json = try loadHooksJson()
        XCTAssertEqual(managedEntries(in: json, event: "Stop").count, 1)
    }

    func test_installBacksUpToClaudeMonitorSuffixedFile() throws {
        try writeFixture("codex-hooks-with-foreign-entries")
        // A pre-existing hooks.json.bak owned by another tool must survive untouched.
        let foreignBackup = dir.appendingPathComponent("hooks.json.bak")
        try "foreign backup".write(to: foreignBackup, atomically: true, encoding: .utf8)

        try HookInstaller.installCodexHook(configDir: dir)

        XCTAssertEqual(try String(contentsOf: foreignBackup, encoding: .utf8), "foreign backup")
        let ourBackup = dir.appendingPathComponent("hooks.json.claude-monitor.bak")
        XCTAssertTrue(FileManager.default.fileExists(atPath: ourBackup.path))
    }

    func test_uninstallRemovesOnlyOurEntries() throws {
        try writeFixture("codex-hooks-with-foreign-entries")
        try HookInstaller.installCodexHook(configDir: dir)
        try HookInstaller.uninstallCodexHook(configDir: dir)
        let json = try loadHooksJson()
        let hooks = try XCTUnwrap(json["hooks"] as? [String: Any])

        XCTAssertTrue(managedEntries(in: json, event: "Stop").isEmpty)
        XCTAssertNil(hooks["Stop"], "events left with no entries are dropped")
        let sessionStart = try XCTUnwrap(hooks["SessionStart"] as? [[String: Any]])
        XCTAssertEqual(sessionStart.count, 1, "foreign entry must survive uninstall")
        XCTAssertEqual(try HookInstaller.inspectCodexHook(configDir: dir).status, .notInstalled)
    }

    func test_inspectDetectsModifiedCommand() throws {
        try HookInstaller.installCodexHook(configDir: dir)
        var json = try loadHooksJson()
        var hooks = try XCTUnwrap(json["hooks"] as? [String: Any])
        var entries = try XCTUnwrap(hooks["Stop"] as? [[String: Any]])
        var inner = try XCTUnwrap(entries[0]["hooks"] as? [[String: Any]])
        inner[0]["command"] = "$HOME/.claude-monitor/codex-hook.sh Stop --managed-by=claude-monitor --version=\(HookInstaller.codexCurrentVersion) --extra"
        entries[0]["hooks"] = inner
        hooks["Stop"] = entries
        json["hooks"] = hooks
        try JSONSerialization.data(withJSONObject: json).write(to: hooksURL)

        XCTAssertEqual(try HookInstaller.inspectCodexHook(configDir: dir).status, .modifiedExternally)
    }

    func test_inspectIgnoresClaudeSettingsFile() throws {
        // A settings.json in the same dir (or none at all) must not affect the Codex kind,
        // which reads hooks.json only.
        try "{\"hooks\":{}}".write(to: dir.appendingPathComponent("settings.json"),
                                   atomically: true, encoding: .utf8)
        XCTAssertEqual(try HookInstaller.inspectCodexHook(configDir: dir).status, .notInstalled)
    }
}
