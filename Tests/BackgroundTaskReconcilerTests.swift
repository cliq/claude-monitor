import XCTest
@testable import ClaudeMonitor

final class BackgroundTaskReconcilerTests: XCTestCase {
    private var directory: URL!
    private var transcript: URL { directory.appendingPathComponent("session.jsonl") }

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data().write(to: transcript)
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: directory)
    }

    private func notification(_ id: String, status: String = "killed", session: String = "s",
                              type: String = "queue-operation", operation: String = "enqueue") throws -> Data {
        var data = try JSONSerialization.data(withJSONObject: [
            "type": type, "operation": operation, "sessionId": session,
            "content": "<task-notification>\n<task-id>\(id)</task-id>\n<tool-use-id>tool-1</tool-use-id>\n<status>\(status)</status>\n<summary>Task was stopped by the user</summary>\n</task-notification>"
        ])
        data.append(10)
        return data
    }

    private func append(_ data: Data) throws {
        let file = try FileHandle(forWritingTo: transcript)
        defer { try? file.close() }
        try file.seekToEnd()
        try file.write(contentsOf: data)
    }

    private func event(_ hook: HookName = .stop, tasks: [String] = ["bxudwrnvt"],
                       count: Int? = nil, path: String? = nil) -> HookEvent {
        HookEvent(hook: hook, sessionId: "s", tty: "/dev/ttys001", pid: 1,
                  cwd: "/work/mbl-8450", ts: 0, promptPreview: nil, toolName: nil,
                  notificationType: nil, message: nil, backgroundTasksActive: count ?? tasks.count,
                  transcriptPath: path ?? transcript.path, backgroundTaskIDs: tasks)
    }

    func test_cancelledShellLeavesBackgroundWorkingWithoutAnotherHook() throws {
        let clock = FakeClock()
        var doneEvents = 0
        let store = SessionStore(clock: clock, onEventApplied: { event in
            if event.hook == .stop && event.backgroundTasksActive == 0 { doneEvents += 1 }
        })
        store.apply(event(.userPromptSubmit))
        store.apply(event())
        XCTAssertEqual(store.orderedSessions[0].state, .backgroundWorking)
        let stoppedAt = store.orderedSessions[0].enteredStateAt
        let reconciler = BackgroundTaskReconciler(store: store)
        let initial = expectation(description: "initial read")
        reconciler.sweep { initial.fulfill() }
        wait(for: [initial], timeout: 3)
        XCTAssertEqual(store.orderedSessions[0].backgroundTaskCount, 1)

        // Actual 8450 cancellation shape: an enqueue record, no subsequent Stop.
        try append(notification("bxudwrnvt"))
        clock.advance(by: 5)
        let cancelled = expectation(description: "cancelled")
        reconciler.sweep { cancelled.fulfill() }
        wait(for: [cancelled], timeout: 3)
        XCTAssertEqual(store.orderedSessions[0].state, .waiting)
        XCTAssertEqual(store.orderedSessions[0].backgroundTaskCount, 0)
        XCTAssertEqual(store.orderedSessions[0].enteredStateAt.timeIntervalSince(stoppedAt), 5)
        XCTAssertEqual(doneEvents, 1, "completion uses the normal notification path exactly once")

        let repeated = expectation(description: "repeat")
        reconciler.sweep { repeated.fulfill() }
        wait(for: [repeated], timeout: 3)
        XCTAssertEqual(doneEvents, 1)
    }

    func test_multipleTasksOnlyWaitAfterLastTrackedTaskEnds() {
        let store = SessionStore(clock: FakeClock())
        store.apply(event(tasks: ["a", "b"]))
        store.completeBackgroundTasks(sessionId: "s", transcriptPath: transcript.path, taskIDs: ["a", "unknown"])
        XCTAssertEqual(store.orderedSessions[0].state, .backgroundWorking)
        XCTAssertEqual(store.orderedSessions[0].backgroundTaskCount, 1)
        XCTAssertEqual(store.orderedSessions[0].backgroundTaskIDs, ["b"])
        store.completeBackgroundTasks(sessionId: "s", transcriptPath: transcript.path, taskIDs: ["a"])
        XCTAssertEqual(store.orderedSessions[0].backgroundTaskCount, 1)
        store.completeBackgroundTasks(sessionId: "s", transcriptPath: transcript.path, taskIDs: ["b"])
        XCTAssertEqual(store.orderedSessions[0].state, .waiting)
    }

    func test_lateReadCannotOverwriteNewTurnPermissionOrChangedTranscript() {
        for hook in [HookName.userPromptSubmit, .notification, .sessionEnd] {
            let store = SessionStore(clock: FakeClock())
            store.apply(event())
            store.apply(event(hook))
            let before = store.orderedSessions
            store.completeBackgroundTasks(sessionId: "s", transcriptPath: transcript.path, taskIDs: ["bxudwrnvt"])
            XCTAssertEqual(store.orderedSessions, before)
        }
        let store = SessionStore(clock: FakeClock())
        store.apply(event(path: "/new/transcript.jsonl"))
        store.completeBackgroundTasks(sessionId: "s", transcriptPath: transcript.path, taskIDs: ["bxudwrnvt"])
        XCTAssertEqual(store.orderedSessions[0].state, .backgroundWorking)
    }

    func test_tasksWithoutIdentityRemainCounted() {
        let store = SessionStore(clock: FakeClock())
        store.apply(event(tasks: ["a"], count: 2))
        store.completeBackgroundTasks(sessionId: "s", transcriptPath: transcript.path, taskIDs: ["a"])
        XCTAssertEqual(store.orderedSessions[0].state, .backgroundWorking)
        XCTAssertEqual(store.orderedSessions[0].backgroundTaskCount, 1)
    }

    func test_idleAndCompactionPreserveTrackedTasks() {
        let store = SessionStore(clock: FakeClock())
        store.apply(event())
        for hook in [HookName.notification, .sessionStart] {
            store.apply(HookEvent(hook: hook, sessionId: "s", tty: "", pid: 1, cwd: "/work",
                                  ts: 0, promptPreview: nil, toolName: nil,
                                  notificationType: "idle_prompt", message: "Claude is waiting for your input",
                                  source: "compact"))
            XCTAssertEqual(store.orderedSessions[0].backgroundTaskIDs, ["bxudwrnvt"])
            XCTAssertEqual(store.orderedSessions[0].transcriptPath, transcript.path)
        }
    }

    func test_readerHandlesPartialWritesDuplicatesAndAllTerminalStatuses() throws {
        let reader = BackgroundTaskTranscriptReader(sessionId: "s", path: transcript.path)
        let data = try notification("a")
        try append(data.dropLast(5))
        XCTAssertEqual(try reader.readCompletedTaskIDs(), [])
        try append(data.suffix(5))
        try append(data)
        for status in ["completed", "failed", "cancelled", "canceled", "stopped"] {
            try append(notification(status, status: status))
        }
        let expected: Set<String> = ["a", "completed", "failed", "cancelled", "canceled", "stopped"]
        XCTAssertEqual(try reader.readCompletedTaskIDs(), expected)
        XCTAssertEqual(try reader.readCompletedTaskIDs(), expected)
    }

    func test_readerIgnoresOtherSessionsUserContentRemovalsAndNonterminalStatus() throws {
        let reader = BackgroundTaskTranscriptReader(sessionId: "s", path: transcript.path)
        try append(notification("other", session: "other"))
        try append(notification("user", type: "user"))
        try append(notification("removed", operation: "remove"))
        try append(notification("running", status: "running"))
        try append(Data("invalid json\n".utf8))
        XCTAssertEqual(try reader.readCompletedTaskIDs(), [])
    }

    func test_readerRecoversAfterLongLinesTruncationAndFileReplacement() throws {
        let reader = BackgroundTaskTranscriptReader(sessionId: "s", path: transcript.path)
        try append(Data(repeating: 120, count: 1_100_000))
        XCTAssertEqual(try reader.readCompletedTaskIDs(), [])
        try append(Data("\n".utf8))
        try append(notification("old"))
        XCTAssertEqual(try reader.readCompletedTaskIDs(), ["old"])
        try Data().write(to: transcript)
        XCTAssertEqual(try reader.readCompletedTaskIDs(), [])
        try notification("replacement").write(to: transcript, options: .atomic)
        XCTAssertEqual(try reader.readCompletedTaskIDs(), ["replacement"])
    }

    func test_missingTranscriptDoesNotClearWorkingState() {
        let store = SessionStore(clock: FakeClock())
        store.apply(event(path: directory.appendingPathComponent("missing.jsonl").path))
        let reconciler = BackgroundTaskReconciler(store: store)
        let finished = expectation(description: "missing file")
        reconciler.sweep { finished.fulfill() }
        wait(for: [finished], timeout: 3)
        XCTAssertEqual(store.orderedSessions[0].state, .backgroundWorking)
        XCTAssertEqual(store.orderedSessions[0].backgroundTaskCount, 1)
    }
}
