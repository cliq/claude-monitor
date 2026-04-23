// Tests/StaleSessionSweeperTests.swift
import XCTest
@testable import ClaudeMonitor

final class StaleSessionSweeperTests: XCTestCase {
    private func event(session: String, pid: Int32, hook: HookName = .sessionStart) -> HookEvent {
        HookEvent(hook: hook, sessionId: session, tty: "/dev/ttys001", pid: pid,
                  cwd: "/p/\(session)", ts: 0, promptPreview: nil, toolName: nil)
    }

    func test_sweepMarksDeadProcessSessionsFinished() {
        let store = SessionStore(clock: FakeClock())
        // My own PID = live.
        store.apply(event(session: "live", pid: ProcessInfo.processInfo.processIdentifier))
        // A pid that won't exist (32-bit max).
        store.apply(event(session: "dead", pid: 2_147_483_000))

        let sweeper = StaleSessionSweeper(store: store)
        sweeper.sweep()

        let byId = Dictionary(uniqueKeysWithValues: store.orderedSessions.map { ($0.id, $0.state) })
        XCTAssertEqual(byId["live"], .waiting)  // unchanged
        XCTAssertEqual(byId["dead"], .finished) // swept
    }

    func test_sweepIgnoresAlreadyFinishedSessions() {
        let store = SessionStore(clock: FakeClock())
        store.apply(event(session: "done", pid: 2_147_483_000, hook: .sessionStart))
        store.apply(event(session: "done", pid: 2_147_483_000, hook: .sessionEnd))
        let before = store.orderedSessions[0].enteredStateAt

        StaleSessionSweeper(store: store).sweep()
        XCTAssertEqual(store.orderedSessions[0].enteredStateAt, before,
                       "already-finished sessions must not have enteredStateAt bumped")
    }
}
