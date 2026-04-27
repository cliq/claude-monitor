// Tests/HookScriptTests.swift
import XCTest
@testable import ClaudeMonitor

final class HookScriptTests: XCTestCase {
    func test_hookScriptPostsEnrichedPayload() async throws {
        let scriptURL = try XCTUnwrap(findHookScript(), "could not find hook.sh")

        var received: [HookEvent] = []
        let expect = expectation(description: "event")
        let server = EventServer { event in
            received.append(event)
            expect.fulfill()
        }
        try server.start()
        defer { server.stop() }

        // Write the port file where hook.sh expects it — use a temp dir via $HOME override.
        let tmpHome = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("claude-monitor-hooktest-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: tmpHome.appendingPathComponent(".claude-monitor"),
            withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpHome) }

        let portFile = tmpHome.appendingPathComponent(".claude-monitor/port")
        try "\(server.port!)\n".write(to: portFile, atomically: true, encoding: .utf8)

        // Run hook.sh with HOME pointing at our temp dir.
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/bash")
        proc.arguments = [scriptURL.path, "UserPromptSubmit"]
        var env = ProcessInfo.processInfo.environment
        env["HOME"] = tmpHome.path
        proc.environment = env

        let inputPipe = Pipe()
        proc.standardInput = inputPipe
        try proc.run()
        inputPipe.fileHandleForWriting.write(#"""
        {"session_id":"sess-1","prompt":"Hello world from the test"}
        """#.data(using: .utf8)!)
        try inputPipe.fileHandleForWriting.close()
        proc.waitUntilExit()
        XCTAssertEqual(proc.terminationStatus, 0)

        await fulfillment(of: [expect], timeout: 3)
        XCTAssertEqual(received.count, 1)
        XCTAssertEqual(received[0].sessionId, "sess-1")
        XCTAssertEqual(received[0].hook, .userPromptSubmit)
        XCTAssertEqual(received[0].promptPreview, "Hello world from the test")
    }

    func test_hookScriptForwardsNotificationFields() async throws {
        let scriptURL = try XCTUnwrap(findHookScript())

        var received: [HookEvent] = []
        let expect = expectation(description: "event")
        let server = EventServer { event in
            received.append(event)
            expect.fulfill()
        }
        try server.start()
        defer { server.stop() }

        let tmpHome = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("claude-monitor-hooktest-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: tmpHome.appendingPathComponent(".claude-monitor"),
            withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpHome) }

        try "\(server.port!)\n".write(
            to: tmpHome.appendingPathComponent(".claude-monitor/port"),
            atomically: true, encoding: .utf8)

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/bash")
        proc.arguments = [scriptURL.path, "Notification"]
        var env = ProcessInfo.processInfo.environment
        env["HOME"] = tmpHome.path
        proc.environment = env

        let inputPipe = Pipe()
        proc.standardInput = inputPipe
        try proc.run()
        inputPipe.fileHandleForWriting.write(#"""
        {"session_id":"s1","notification_type":"idle_prompt","message":"You there?"}
        """#.data(using: .utf8)!)
        try inputPipe.fileHandleForWriting.close()
        proc.waitUntilExit()
        XCTAssertEqual(proc.terminationStatus, 0)

        await fulfillment(of: [expect], timeout: 3)
        XCTAssertEqual(received[0].notificationType, "idle_prompt")
        XCTAssertEqual(received[0].message, "You there?")
    }

    /// Resolve the hook.sh location. Prefer the bundled test resource (the xcodegen
    /// project adds scripts/hook.sh as a test-target resource), fallback to walking
    /// up from the test-bundle URL to the repo root.
    private func findHookScript() -> URL? {
        if let inBundle = Bundle(for: Self.self).url(forResource: "hook", withExtension: "sh") {
            return inBundle
        }
        var cursor = Bundle(for: Self.self).bundleURL
        for _ in 0..<8 {
            let candidate = cursor.appendingPathComponent("scripts/hook.sh")
            if FileManager.default.isExecutableFile(atPath: candidate.path) {
                return candidate
            }
            cursor.deleteLastPathComponent()
        }
        return nil
    }
}
