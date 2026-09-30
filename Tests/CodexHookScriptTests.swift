// Tests/CodexHookScriptTests.swift
import XCTest
@testable import ClaudeMonitor

final class CodexHookScriptTests: XCTestCase {

    private func runScript(hook: String, stdin: String, expectEvent: Bool = true,
                           underManagedDaemon: Bool = false, cwd: URL? = nil,
                           codexHome: String? = nil) async throws -> HookEvent? {
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
        if underManagedDaemon {
            // A parent bash whose command line looks like Codex's shared daemon
            // (`codex app-server --listen unix:// --managed-daemon`). The trailing
            // `exit` keeps bash from exec'ing the hook, so it stays the parent.
            proc.arguments = ["-c", "/bin/bash \"$1\" \"$2\"; exit 0",
                              "codex app-server --listen unix:// --managed-daemon", scriptURL.path, hook]
        } else {
            proc.arguments = [scriptURL.path, hook]
        }
        var env = ProcessInfo.processInfo.environment
        env["HOME"] = tmpHome.path
        if let codexHome { env["CODEX_HOME"] = codexHome }
        proc.environment = env
        if let cwd { proc.currentDirectoryURL = cwd }

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

    func test_compactionSourceReachesStoreWithoutResettingWorking() async throws {
        let received = try await runScript(hook: "SessionStart",
            stdin: #"{"session_id":"s","source":"compact"}"#)
        let event = try XCTUnwrap(received)
        XCTAssertEqual(event.source, "compact")
        let store = SessionStore(clock: FakeClock())
        store.apply(HookEvent(hook: .userPromptSubmit, sessionId: "codex:s", tty: "", pid: 1,
                              cwd: "/", ts: 0, promptPreview: "Work", toolName: nil,
                              notificationType: nil, message: nil, provider: .codex))
        store.apply(event)
        XCTAssertEqual(store.orderedSessions[0].state, .working)
        XCTAssertEqual(store.orderedSessions[0].lastPromptPreview, "Work")
    }

    func test_toolOutputRestoresWorkingAfterApprovalWithoutChangingPreview() async throws {
        let received = try await runScript(hook: "PostToolUse",
            stdin: #"{"session_id":"s","tool_name":"Bash","tool_response":"done","prompt":"must not replace the user prompt"}"#)
        let event = try XCTUnwrap(received)
        XCTAssertEqual(event.hook, .postToolUse)
        XCTAssertEqual(event.toolName, "Bash")
        XCTAssertNil(event.promptPreview)
        XCTAssertEqual(StateMachine.transition(from: .needsYou, for: event.hook), .working)
    }

    func test_largeToolOutputDoesNotExceedProcessEnvironmentLimit() async throws {
        let stdin = "{\"session_id\":\"s\",\"tool_name\":\"Bash\",\"tool_response\":\""
            + String(repeating: "x", count: 300_000) + "\"}"
        let received = try await runScript(hook: "PostToolUse", stdin: stdin)
        let event = try XCTUnwrap(received)
        XCTAssertEqual(event.hook, .postToolUse)
        XCTAssertEqual(event.toolName, "Bash")
    }

    func test_directParentIsReportedAsTheCodexProcess() async throws {
        let received = try await runScript(hook: "Stop", stdin: #"{"session_id":"s"}"#)
        let event = try XCTUnwrap(received)
        XCTAssertEqual(event.pid, getpid(), "without the daemon, the hook's parent is the codex process")
    }

    func test_managedDaemonParentIsReplacedByTheMatchingTUI() async throws {
        let fixture = try FakeCodexTUI()
        defer { fixture.stop() }
        let tui = try fixture.launch()

        let received = try await runScript(
            hook: "UserPromptSubmit", stdin: #"{"session_id":"s","prompt":"hi"}"#,
            underManagedDaemon: true, cwd: fixture.project, codexHome: fixture.codexHome)
        let event = try XCTUnwrap(received)
        XCTAssertEqual(event.pid, tui.processIdentifier,
                       "the daemon's pid is shared by every session and never exits")
    }

    func test_managedDaemonParentWithoutAMatchingTUIReportsNoProcess() async throws {
        let fixture = try FakeCodexTUI()
        defer { fixture.stop() }
        _ = try fixture.launch()

        // Same CODEX_HOME, different cwd: some other session's TUI.
        let elsewhere = fixture.root.appendingPathComponent("elsewhere")
        try FileManager.default.createDirectory(at: elsewhere, withIntermediateDirectories: true)
        let received = try await runScript(
            hook: "Stop", stdin: #"{"session_id":"s"}"#,
            underManagedDaemon: true, cwd: elsewhere, codexHome: fixture.codexHome)
        let event = try XCTUnwrap(received)
        XCTAssertEqual(event.pid, 0)
        XCTAssertEqual(event.tty, "")
    }

    func test_managedDaemonParentWithSeveralMatchingTUIsReportsNoProcess() async throws {
        let fixture = try FakeCodexTUI()
        defer { fixture.stop() }
        _ = try fixture.launch()
        _ = try fixture.launch()

        let received = try await runScript(
            hook: "Stop", stdin: #"{"session_id":"s"}"#,
            underManagedDaemon: true, cwd: fixture.project, codexHome: fixture.codexHome)
        let event = try XCTUnwrap(received)
        XCTAssertEqual(event.pid, 0, "guessing could focus another session's terminal")
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

/// A long-running process whose executable is `…/codex`, started in `project` with
/// a private `CODEX_HOME`, so real Codex TUIs on the machine never match it.
private final class FakeCodexTUI {
    let root: URL
    let project: URL
    let codexHome: String
    private let executable: URL
    private var processes: [Process] = []

    init() throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("claude-monitor-fakecodex-\(UUID().uuidString)")
        project = root.appendingPathComponent("project")
        codexHome = root.appendingPathComponent("codex-home").path
        executable = root.appendingPathComponent("bin/codex")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: executable.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        // An ad-hoc signed copy, not a symlink: `ps eww` hides the environment
        // of Apple platform binaries, and the hook matches on CODEX_HOME there.
        try FileManager.default.copyItem(at: URL(fileURLWithPath: "/bin/sleep"), to: executable)
        let sign = Process()
        sign.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        sign.arguments = ["-f", "-s", "-", executable.path]
        sign.standardError = FileHandle.nullDevice
        try sign.run()
        sign.waitUntilExit()
    }

    func launch() throws -> Process {
        let proc = Process()
        proc.executableURL = executable
        proc.arguments = ["30"]
        proc.currentDirectoryURL = project
        var env = ProcessInfo.processInfo.environment
        env["CODEX_HOME"] = codexHome
        proc.environment = env
        try proc.run()
        processes.append(proc)
        return proc
    }

    func stop() {
        processes.forEach { $0.terminate() }
        try? FileManager.default.removeItem(at: root)
    }
}
