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

    func test_finishedSessionIsRemovedAfter10Seconds() {
        let clock = FakeClock()
        let store = SessionStore(clock: clock, finishedRemovalDelay: 10)
        store.apply(event(.sessionStart))
        store.apply(event(.sessionEnd))

        XCTAssertEqual(store.orderedSessions.count, 1)
        XCTAssertEqual(store.orderedSessions[0].state, .finished)

        clock.advance(by: 9)
        store.tickRemovalTimer()
        XCTAssertEqual(store.orderedSessions.count, 1, "still within 10s window")

        clock.advance(by: 2)  // now 11s after finished
        store.tickRemovalTimer()
        XCTAssertEqual(store.orderedSessions.count, 0, "should be removed past 10s")
    }

    func test_finishedSessionCanBeRevivedBeforeRemoval() {
        // Edge case: an event arrives for a finished session before the removal timer fires.
        // Once finished is terminal per the state machine, we stay finished. But the timer
        // still runs from the original finished moment — document this.
        let clock = FakeClock()
        let store = SessionStore(clock: clock, finishedRemovalDelay: 10)
        store.apply(event(.sessionStart))
        store.apply(event(.sessionEnd))
        clock.advance(by: 3)
        store.apply(event(.userPromptSubmit))  // should be ignored (finished is terminal)
        XCTAssertEqual(store.orderedSessions[0].state, .finished)
        clock.advance(by: 8)
        store.tickRemovalTimer()
        XCTAssertEqual(store.orderedSessions.count, 0)
    }
}
