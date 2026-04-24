import XCTest
@testable import ClaudeMonitor

final class SessionStoreTests: XCTestCase {
    private func event(_ hook: HookName,
                       session: String = "s1",
                       tty: String = "/dev/ttys001",
                       pid: Int32 = 100,
                       cwd: String = "/Users/leo/Projects/foo",
                       ts: Int = 0,
                       promptPreview: String? = nil) -> HookEvent {
        HookEvent(hook: hook, sessionId: session, tty: tty, pid: pid, cwd: cwd,
                  ts: ts, promptPreview: promptPreview, toolName: nil)
    }

    func test_sessionStartCreatesSessionInWaiting() {
        let store = SessionStore(clock: FakeClock())
        store.apply(event(.sessionStart))
        XCTAssertEqual(store.orderedSessions.count, 1)
        XCTAssertEqual(store.orderedSessions[0].id, "s1")
        XCTAssertEqual(store.orderedSessions[0].state, .waiting)
        XCTAssertEqual(store.orderedSessions[0].projectName, "foo")
    }

    func test_userPromptSubmitMovesToWorkingAndStoresPreview() {
        let store = SessionStore(clock: FakeClock())
        store.apply(event(.sessionStart))
        store.apply(event(.userPromptSubmit, promptPreview: "Hello world"))

        XCTAssertEqual(store.orderedSessions[0].state, .working)
        XCTAssertEqual(store.orderedSessions[0].lastPromptPreview, "Hello world")
    }

    func test_promptPreviewSticksBetweenPrompts() {
        let store = SessionStore(clock: FakeClock())
        store.apply(event(.sessionStart))
        store.apply(event(.userPromptSubmit, promptPreview: "First"))
        store.apply(event(.stop)) // no preview on Stop
        XCTAssertEqual(store.orderedSessions[0].lastPromptPreview, "First")
    }

    func test_unknownSessionOnNonStartEventIsSynthesized() {
        let store = SessionStore(clock: FakeClock())
        store.apply(event(.userPromptSubmit, promptPreview: "p"))
        XCTAssertEqual(store.orderedSessions.count, 1)
        XCTAssertEqual(store.orderedSessions[0].state, .working)
    }

    func test_multipleSessionsInsertInOrder() {
        let store = SessionStore(clock: FakeClock())
        store.apply(event(.sessionStart, session: "a", tty: "/dev/ttys001", cwd: "/p/alpha"))
        store.apply(event(.sessionStart, session: "b", tty: "/dev/ttys002", cwd: "/p/beta"))
        store.apply(event(.sessionStart, session: "c", tty: "/dev/ttys003", cwd: "/p/gamma"))
        XCTAssertEqual(store.orderedSessions.map(\.id), ["a", "b", "c"])
    }

    func test_stateChangeUpdatesEnteredStateAt() {
        let clock = FakeClock()
        let store = SessionStore(clock: clock)
        store.apply(event(.sessionStart))
        let t0 = store.orderedSessions[0].enteredStateAt
        clock.advance(by: 5)
        store.apply(event(.userPromptSubmit))
        let t1 = store.orderedSessions[0].enteredStateAt
        XCTAssertEqual(t1.timeIntervalSince(t0), 5, accuracy: 0.001)
    }

    func test_repeatedSameStateEventDoesNotResetTimer() {
        // Two Stop events in a row (shouldn't happen normally, but guard against it).
        let clock = FakeClock()
        let store = SessionStore(clock: clock)
        store.apply(event(.sessionStart))
        store.apply(event(.userPromptSubmit))
        store.apply(event(.stop))
        let t1 = store.orderedSessions[0].enteredStateAt
        clock.advance(by: 3)
        store.apply(event(.stop))
        XCTAssertEqual(store.orderedSessions[0].enteredStateAt, t1,
                       "enteredStateAt must only reset when the state actually changes")
    }

    func test_sessionEndRemovesSessionImmediately() {
        let store = SessionStore(clock: FakeClock())
        store.apply(event(.sessionStart))
        XCTAssertEqual(store.orderedSessions.count, 1)

        store.apply(event(.sessionEnd))
        XCTAssertEqual(store.orderedSessions.count, 0, "finished sessions should disappear right away")
    }

    func test_sessionEndForUnknownSessionIsIgnored() {
        let store = SessionStore(clock: FakeClock())
        store.apply(event(.sessionEnd, session: "ghost"))
        XCTAssertEqual(store.orderedSessions.count, 0, "must not synthesize a finished session out of thin air")
    }

    func test_markFinishedRemovesSessionImmediately() {
        let store = SessionStore(clock: FakeClock())
        store.apply(event(.sessionStart))
        store.markFinished(sessionId: "s1")
        XCTAssertEqual(store.orderedSessions.count, 0)
    }

}
