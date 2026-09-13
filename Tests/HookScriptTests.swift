// Tests/HookScriptTests.swift
import XCTest
@testable import ClaudeMonitor

final class HookScriptTests: XCTestCase {
    private func runScript(hook: String, stdin: String) async throws -> HookEvent {
        let scriptURL = try XCTUnwrap(findHookScript())
        var received: HookEvent?
        let expect = expectation(description: "event")
        let server = EventServer { event in received = event; expect.fulfill() }
        try server.start()
        defer { server.stop() }
        let tmpHome = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("claude-monitor-hooktest-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: tmpHome.appendingPathComponent(".claude-monitor"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpHome) }
        try "\(server.port!)\n".write(to: tmpHome.appendingPathComponent(".claude-monitor/port"),
                                    atomically: true, encoding: .utf8)
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/bash")
        proc.arguments = [scriptURL.path, hook]
        var env = ProcessInfo.processInfo.environment
        env["HOME"] = tmpHome.path
        proc.environment = env
        let input = Pipe()
        let output = Pipe()
        proc.standardInput = input
        proc.standardOutput = output
        try proc.run()
        input.fileHandleForWriting.write(Data(stdin.utf8))
        try input.fileHandleForWriting.close()
        proc.waitUntilExit()
        XCTAssertEqual(proc.terminationStatus, 0)
        XCTAssertTrue(output.fileHandleForReading.readDataToEndOfFile().isEmpty,
                      "the monitor must never send hook decisions to Claude")
        await fulfillment(of: [expect], timeout: 3)
        return try XCTUnwrap(received)
    }

    func test_compactionSourceReachesStoreWithoutResettingWorking() async throws {
        let event = try await runScript(hook: "SessionStart",
            stdin: #"{"session_id":"s","source":"compact"}"#)
        XCTAssertEqual(event.source, "compact")
        let store = SessionStore(clock: FakeClock())
        store.apply(HookEvent(hook: .userPromptSubmit, sessionId: "s", tty: "", pid: 1,
                              cwd: "/", ts: 0, promptPreview: "Work", toolName: nil,
                              notificationType: nil, message: nil))
        store.apply(event)
        XCTAssertEqual(store.orderedSessions[0].state, .working)
        XCTAssertEqual(store.orderedSessions[0].lastPromptPreview, "Work")
    }

    func test_answeredQuestionToolOutputRestoresWorking() async throws {
        let event = try await runScript(hook: "PostToolUse",
            stdin: #"{"session_id":"s","tool_name":"AskUserQuestion","tool_response":{"answers":{"Layout":"Queue screen"}},"prompt":"must not replace the user prompt"}"#)
        XCTAssertEqual(event.hook, .postToolUse)
        XCTAssertEqual(event.toolName, "AskUserQuestion")
        XCTAssertNil(event.promptPreview)
        XCTAssertEqual(StateMachine.transition(from: .needsYou, for: event.hook), .working)
    }

    func test_largeToolOutputDoesNotExceedProcessEnvironmentLimit() async throws {
        let stdin = "{\"session_id\":\"s\",\"tool_name\":\"Read\",\"tool_response\":\""
            + String(repeating: "x", count: 300_000) + "\"}"
        let event = try await runScript(hook: "PostToolUse", stdin: stdin)
        XCTAssertEqual(event.hook, .postToolUse)
        XCTAssertEqual(event.toolName, "Read")
    }

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
        let scriptURL = try XCTUnwrap(findHookScript(), "could not find hook.sh")

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
        XCTAssertEqual(received.count, 1)
        XCTAssertEqual(received[0].hook, .notification)
        XCTAssertEqual(received[0].notificationType, "idle_prompt")
        XCTAssertEqual(received[0].message, "You there?")
    }

    func test_hookScriptCountsActiveBackgroundTasks() async throws {
        let scriptURL = try XCTUnwrap(findHookScript(), "could not find hook.sh")
        var received: [HookEvent] = []
        let expect = expectation(description: "event")
        let server = EventServer { event in received.append(event); expect.fulfill() }
        try server.start(); defer { server.stop() }

        let tmpHome = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("claude-monitor-hooktest-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: tmpHome.appendingPathComponent(".claude-monitor"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpHome) }
        try "\(server.port!)\n".write(to: tmpHome.appendingPathComponent(".claude-monitor/port"),
                                      atomically: true, encoding: .utf8)

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/bash")
        proc.arguments = [scriptURL.path, "Stop"]
        var env = ProcessInfo.processInfo.environment
        env["HOME"] = tmpHome.path
        proc.environment = env
        let inputPipe = Pipe()
        proc.standardInput = inputPipe
        try proc.run()
        inputPipe.fileHandleForWriting.write(#"""
        {"session_id":"s","background_tasks":[{"id":"a","type":"subagent","status":"running"},{"id":"b","type":"shell","status":"completed"},{"id":"c","type":"workflow","status":"in_progress"},{"id":"d","type":"shell","status":"killed"},{"id":"e","type":"shell","status":"stopped"},{"id":"f","type":"monitor","status":"running"},{"id":"g","type":"monitor_ws","status":"running"}]}
        """#.data(using: .utf8)!)
        try inputPipe.fileHandleForWriting.close()
        proc.waitUntilExit()
        XCTAssertEqual(proc.terminationStatus, 0)

        await fulfillment(of: [expect], timeout: 3)
        XCTAssertEqual(received.first?.backgroundTasksActive, 2)
    }

    func test_hookScriptOmitsSyntheticTaskNotificationPreview() async throws {
        let scriptURL = try XCTUnwrap(findHookScript(), "could not find hook.sh")
        var received: [HookEvent] = []
        let expect = expectation(description: "event")
        let server = EventServer { event in received.append(event); expect.fulfill() }
        try server.start(); defer { server.stop() }

        let tmpHome = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("claude-monitor-hooktest-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: tmpHome.appendingPathComponent(".claude-monitor"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpHome) }
        try "\(server.port!)\n".write(to: tmpHome.appendingPathComponent(".claude-monitor/port"),
                                      atomically: true, encoding: .utf8)

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
        {"session_id":"s","prompt":"<task-notification>\n<task-id>abc</task-id>\n</task-notification>"}
        """#.data(using: .utf8)!)
        try inputPipe.fileHandleForWriting.close()
        proc.waitUntilExit()
        XCTAssertEqual(proc.terminationStatus, 0)

        await fulfillment(of: [expect], timeout: 3)
        XCTAssertEqual(received.count, 1)
        XCTAssertNil(received[0].promptPreview)
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
