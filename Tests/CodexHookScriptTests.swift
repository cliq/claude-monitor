// Tests/CodexHookScriptTests.swift
import XCTest
@testable import ClaudeMonitor

final class CodexHookScriptTests: XCTestCase {

    private func runScript(hook: String, stdin: String, expectEvent: Bool = true) async throws -> HookEvent? {
        let scriptURL = try XCTUnwrap(findScript(), "could not find codex-hook.sh")

        var received: [HookEvent] = []
        let expect = expectation(description: "event")
        expect.assertForOverFulfill = false
        expect.isInverted = !expectEvent
        let server = EventServer { event in
            received.append(event)
            expect.fulfill()
        }
        try server.start()
        defer { server.stop() }

        let tmpHome = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("claude-monitor-codexhooktest-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: tmpHome.appendingPathComponent(".claude-monitor"),
            withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpHome) }

        try "\(server.port!)\n".write(
            to: tmpHome.appendingPathComponent(".claude-monitor/port"),
            atomically: true, encoding: .utf8)

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/bash")
        proc.arguments = [scriptURL.path, hook]
        var env = ProcessInfo.processInfo.environment
        env["HOME"] = tmpHome.path
        proc.environment = env

        let inputPipe = Pipe()
        let outputPipe = Pipe()
        proc.standardInput = inputPipe
        proc.standardOutput = outputPipe
        try proc.run()
        inputPipe.fileHandleForWriting.write(stdin.data(using: .utf8)!)
        try inputPipe.fileHandleForWriting.close()
        proc.waitUntilExit()
        XCTAssertEqual(proc.terminationStatus, 0, "codex-hook.sh must always exit 0")

        // A PermissionRequest hook that prints to stdout could allow/deny the
        // request — the script must be a pure observer for every event.
        let stdout = outputPipe.fileHandleForReading.readDataToEndOfFile()
        XCTAssertTrue(stdout.isEmpty, "codex-hook.sh must never write to stdout")

        // Inverted expectations fail on fulfillment, so the same wait covers both
        // "an event must arrive" and "no event may arrive".
        await fulfillment(of: [expect], timeout: expectEvent ? 3 : 1)
        return received.first
    }

    func test_namespacesSessionIdAndSetsProvider() async throws {
        let received = try await runScript(
            hook: "UserPromptSubmit",
            stdin: #"{"session_id":"abc-123","hook_event_name":"UserPromptSubmit","cwd":"/tmp/proj","prompt":"Fix the tests"}"#)
        let event = try XCTUnwrap(received)

        XCTAssertEqual(event.hook, .userPromptSubmit)
        XCTAssertEqual(event.sessionId, "codex:abc-123")
        XCTAssertEqual(event.provider, .codex)
        XCTAssertEqual(event.cwd, "/tmp/proj")
        XCTAssertEqual(event.promptPreview, "Fix the tests")
    }

    func test_normalizesPermissionRequestToNotification() async throws {
        let received = try await runScript(
            hook: "PermissionRequest",
            stdin: #"{"session_id":"abc-123","hook_event_name":"PermissionRequest","tool_name":"shell"}"#)
        let event = try XCTUnwrap(received)

        XCTAssertEqual(event.hook, .notification)
        XCTAssertEqual(event.notificationType, "permission_prompt")
        XCTAssertEqual(event.provider, .codex)
        XCTAssertEqual(event.message, "Codex needs permission to run shell")
        XCTAssertEqual(event.toolName, "shell")
    }

    func test_passesThroughLifecycleEvents() async throws {
        let received = try await runScript(
            hook: "SessionEnd",
            stdin: #"{"session_id":"abc-123","hook_event_name":"SessionEnd"}"#)
        let event = try XCTUnwrap(received)

        XCTAssertEqual(event.hook, .sessionEnd)
        XCTAssertEqual(event.sessionId, "codex:abc-123")
    }

    func test_postsNothingWithoutSessionId() async throws {
        let event = try await runScript(hook: "SessionStart", stdin: "{}", expectEvent: false)
        XCTAssertNil(event, "an unidentifiable session must not create a phantom card")
    }

    /// Resolve the codex-hook.sh location — bundled test resource first, repo fallback.
    private func findScript() -> URL? {
        if let inBundle = Bundle(for: Self.self).url(forResource: "codex-hook", withExtension: "sh") {
            return inBundle
        }
        var cursor = Bundle(for: Self.self).bundleURL
        for _ in 0..<8 {
            let candidate = cursor.appendingPathComponent("scripts/codex-hook.sh")
            if FileManager.default.isExecutableFile(atPath: candidate.path) {
                return candidate
            }
            cursor.deleteLastPathComponent()
        }
        return nil
    }
}
