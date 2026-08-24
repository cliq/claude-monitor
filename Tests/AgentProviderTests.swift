// Tests/AgentProviderTests.swift
import XCTest
@testable import ClaudeMonitor

final class AgentProviderTests: XCTestCase {

    // MARK: HookEvent decoding

    func test_eventWithoutProviderDecodesAsClaude() throws {
        let json = """
        {"hook":"SessionStart","session_id":"x","tty":"/dev/ttys001","pid":1,"cwd":"/","ts":1}
        """.data(using: .utf8)!

        let event = try JSONDecoder().decode(HookEvent.self, from: json)
        XCTAssertEqual(event.provider, .claude,
                       "payloads from deployed hook.sh versions carry no provider key")
    }

    func test_eventWithCodexProviderDecodes() throws {
        let json = """
        {"hook":"Stop","provider":"codex","session_id":"codex:x","tty":"","pid":42,"cwd":"/p","ts":1}
        """.data(using: .utf8)!

        let event = try JSONDecoder().decode(HookEvent.self, from: json)
        XCTAssertEqual(event.provider, .codex)
        XCTAssertEqual(event.sessionId, "codex:x")
    }

    // MARK: Session creation

    func test_sessionStoreCarriesProviderOntoNewSessions() {
        let store = SessionStore()
        store.apply(HookEvent(hook: .sessionStart, sessionId: "codex:s1", tty: "", pid: 1,
                              cwd: "/p", ts: 1, promptPreview: nil, toolName: nil,
                              notificationType: nil, message: nil, provider: .codex))
        store.apply(HookEvent(hook: .sessionStart, sessionId: "s2", tty: "", pid: 2,
                              cwd: "/q", ts: 2, promptPreview: nil, toolName: nil,
                              notificationType: nil, message: nil))

        XCTAssertEqual(store.orderedSessions.count, 2)
        XCTAssertEqual(store.orderedSessions[0].provider, .codex)
        XCTAssertEqual(store.orderedSessions[1].provider, .claude)
    }

    func test_namespacedIdsKeepProvidersSeparate() {
        // The same raw uuid from both CLIs must never merge into one card.
        let store = SessionStore()
        store.apply(HookEvent(hook: .sessionStart, sessionId: "uuid-1", tty: "", pid: 1,
                              cwd: "/claude", ts: 1, promptPreview: nil, toolName: nil,
                              notificationType: nil, message: nil))
        store.apply(HookEvent(hook: .userPromptSubmit, sessionId: "codex:uuid-1", tty: "", pid: 2,
                              cwd: "/codex", ts: 2, promptPreview: nil, toolName: nil,
                              notificationType: nil, message: nil, provider: .codex))

        XCTAssertEqual(store.orderedSessions.count, 2)
    }

    // MARK: Codex directory discovery

    func test_scanCodexFindsCodexDirsByMarkerFile() throws {
        let home = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("claude-monitor-codexscan-\(UUID().uuidString)")
        let fm = FileManager.default
        defer { try? fm.removeItem(at: home) }

        // .codex with config.toml → found
        try fm.createDirectory(at: home.appendingPathComponent(".codex"), withIntermediateDirectories: true)
        try "".write(to: home.appendingPathComponent(".codex/config.toml"), atomically: true, encoding: .utf8)
        // .codexwho-work with only auth.json → found
        try fm.createDirectory(at: home.appendingPathComponent(".codexwho-work"), withIntermediateDirectories: true)
        try "".write(to: home.appendingPathComponent(".codexwho-work/auth.json"), atomically: true, encoding: .utf8)
        // .codexwho-empty without markers → skipped
        try fm.createDirectory(at: home.appendingPathComponent(".codexwho-empty"), withIntermediateDirectories: true)
        // .claude with settings.json → not a Codex dir
        try fm.createDirectory(at: home.appendingPathComponent(".claude"), withIntermediateDirectories: true)
        try "{}".write(to: home.appendingPathComponent(".claude/settings.json"), atomically: true, encoding: .utf8)

        let found = ConfigDirectoryDiscovery.scanCodex(home: home).map(\.lastPathComponent)
        XCTAssertEqual(found, [".codex", ".codexwho-work"])
    }

    func test_scanDoesNotPickUpCodexDirs() throws {
        // Claude-only consumers (UsageAccountConfig) must never see Codex dirs.
        let home = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("claude-monitor-claudescan-\(UUID().uuidString)")
        let fm = FileManager.default
        defer { try? fm.removeItem(at: home) }

        try fm.createDirectory(at: home.appendingPathComponent(".codex"), withIntermediateDirectories: true)
        try "".write(to: home.appendingPathComponent(".codex/config.toml"), atomically: true, encoding: .utf8)

        XCTAssertTrue(ConfigDirectoryDiscovery.scan(home: home).isEmpty)
    }
}
