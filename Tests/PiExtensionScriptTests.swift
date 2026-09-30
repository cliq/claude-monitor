import XCTest
@testable import ClaudeMonitor

/// Loads the bundled pi extension in Node (which strips its TypeScript types)
/// against a fake `ExtensionAPI`, fires a scripted sequence of pi events, and
/// checks what reaches a real `EventServer`. Skipped when no Node ≥ 22.6 is found.
final class PiExtensionScriptTests: XCTestCase {

    /// Fake pi runtime: registers the extension's handlers, then awaits each
    /// `[eventName, eventPayload, mode?]` step in order, like pi does.
    private static let harness = """
    const [extPath, stepsJSON] = process.argv.slice(-2);
    const handlers = {};
    const pi = { on(name, fn) { (handlers[name] ??= []).push(fn); } };
    const mod = await import(extPath);
    mod.default(pi);
    for (const [name, payload, mode] of JSON.parse(stepsJSON)) {
      const ctx = { mode: mode ?? "tui", cwd: "/tmp/pi-proj",
                    sessionManager: { getSessionId: () => "sess-1" } };
      for (const fn of handlers[name] ?? []) await fn({ type: name, ...payload }, ctx);
    }
    """

    private func nodeURL() throws -> URL {
        let candidates = ["/opt/homebrew/bin/node", "/usr/local/bin/node"]
            + (ProcessInfo.processInfo.environment["PATH"] ?? "")
                .split(separator: ":").map { "\($0)/node" }
        guard let path = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else {
            throw XCTSkip("node not found")
        }
        return URL(fileURLWithPath: path)
    }

    private func run(_ steps: [[Any]], expectedCount: Int) async throws -> [HookEvent] {
        let node = try nodeURL()
        let ext = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "pi-extension", withExtension: "ts"))

        var received: [HookEvent] = []
        let expect = expectation(description: "events")
        expect.expectedFulfillmentCount = max(expectedCount, 1)
        expect.assertForOverFulfill = true
        expect.isInverted = expectedCount == 0
        let server = EventServer { event in
            received.append(event)
            expect.fulfill()
        }
        try server.start()
        defer { server.stop() }

        let tmpHome = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("claude-monitor-piexttest-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmpHome.appendingPathComponent(".claude-monitor"),
                                                withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpHome) }
        try "\(server.port!)\n".write(to: tmpHome.appendingPathComponent(".claude-monitor/port"),
                                       atomically: true, encoding: .utf8)
        // Node only strips types from .ts files outside node_modules; copy it next to the home.
        let extCopy = tmpHome.appendingPathComponent("claude-monitor.ts")
        try FileManager.default.copyItem(at: ext, to: extCopy)

        let proc = Process()
        proc.executableURL = node
        let stepsJSON = String(data: try JSONSerialization.data(withJSONObject: steps), encoding: .utf8)!
        proc.arguments = ["--input-type=module", "-e", Self.harness, extCopy.path, stepsJSON]
        var env = ProcessInfo.processInfo.environment
        env["HOME"] = tmpHome.path
        proc.environment = env
        let out = Pipe(), err = Pipe()
        proc.standardOutput = out
        proc.standardError = err
        try proc.run()
        proc.waitUntilExit()

        let stderr = String(data: err.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        if stderr.contains("Unknown file extension \".ts\"") || stderr.contains("ERR_UNKNOWN_FILE_EXTENSION") {
            throw XCTSkip("this node cannot strip TypeScript types")
        }
        XCTAssertEqual(proc.terminationStatus, 0, stderr)
        XCTAssertTrue(out.fileHandleForReading.readDataToEndOfFile().isEmpty,
                      "the extension runs inside pi's TUI and must never write to stdout")

        await fulfillment(of: [expect], timeout: expectedCount == 0 ? 1 : 5)
        return received
    }

    func test_fullTurnMapsToMonitorVocabulary() async throws {
        let events = try await run([
            ["session_start", ["reason": "startup"]],
            ["before_agent_start", ["prompt": "Fix the flaky test"]],
            ["agent_start", [:]],
            ["ui_prompt_start", ["reason": "ui_prompt", "kind": "confirm", "title": "Allow rm -rf build?"]],
            ["ui_prompt_end", ["reason": "ui_prompt", "kind": "confirm"]],
            ["agent_settled", [:]],
            ["session_shutdown", ["reason": "quit"]],
        ], expectedCount: 6)

        XCTAssertEqual(events.map(\.hook),
                       [.sessionStart, .userPromptSubmit, .notification, .postToolUse, .stop, .sessionEnd])
        XCTAssertTrue(events.allSatisfy { $0.provider == .pi && $0.sessionId == "pi:sess-1" })
        XCTAssertTrue(events.allSatisfy { $0.cwd == "/tmp/pi-proj" && $0.pid > 0 })
        XCTAssertEqual(events[0].source, "startup")
        XCTAssertEqual(events[1].promptPreview, "Fix the flaky test")
        XCTAssertEqual(events[2].notificationType, "permission_prompt")
        XCTAssertEqual(events[2].message, "Allow rm -rf build?")
    }

    func test_nonConfirmPromptDuringRunIsElicitation() async throws {
        let events = try await run([
            ["agent_start", [:]],
            ["ui_prompt_start", ["reason": "ui_prompt", "kind": "select"]],
        ], expectedCount: 1)

        XCTAssertEqual(events.first?.notificationType, "elicitation_dialog")
        XCTAssertEqual(events.first?.message, "Pi is waiting for your answer")
    }

    func test_promptWhileIdleIsNotReported() async throws {
        // A slash command's dialog: the user is at the keyboard, and the
        // Notification/Stop pair would send two pushes.
        let events = try await run([
            ["ui_prompt_start", ["reason": "ui_prompt", "kind": "select"]],
            ["ui_prompt_end", ["reason": "ui_prompt", "kind": "select"]],
        ], expectedCount: 0)
        XCTAssertTrue(events.isEmpty)
    }

    func test_reloadIsSilent() async throws {
        let events = try await run([
            ["session_shutdown", ["reason": "reload"]],
            ["session_start", ["reason": "reload"]],
        ], expectedCount: 0)
        XCTAssertTrue(events.isEmpty)
    }

    func test_nonInteractiveModesAreIgnored() async throws {
        let events = try await run([
            ["session_start", ["reason": "startup"], "json"],
            ["before_agent_start", ["prompt": "subagent task"], "print"],
            ["agent_settled", [:], "rpc"],
        ], expectedCount: 0)
        XCTAssertTrue(events.isEmpty)
    }
}
