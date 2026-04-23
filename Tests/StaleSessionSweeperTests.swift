// Tests/StaleSessionSweeperTests.swift
import XCTest
@testable import ClaudeMonitor

final class StaleSessionSweeperTests: XCTestCase {
    private func event(session: String, pid: Int32, hook: HookName = .sessionStart) -> HookEvent {
        HookEvent(hook: hook, sessionId: session, tty: "/dev/ttys001", pid: pid,
                  cwd: "/p/\(session)", ts: 0, promptPreview: nil, toolName: nil)
    }

    func test_sweepRemovesDeadProcessSessions() {
        let store = SessionStore(clock: FakeClock())
        // My own PID = live.
        store.apply(event(session: "live", pid: ProcessInfo.processInfo.processIdentifier))
        // A pid that won't exist (32-bit max).
        store.apply(event(session: "dead", pid: 2_147_483_000))

        let sweeper = StaleSessionSweeper(store: store)
        sweeper.sweep()

        let ids = store.orderedSessions.map(\.id)
        XCTAssertEqual(ids, ["live"], "dead session should be removed; live session should remain")
    }
}
