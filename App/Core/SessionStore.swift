// App/Core/SessionStore.swift
import Foundation
import Combine

final class SessionStore: ObservableObject {
    @Published private(set) var orderedSessions: [Session] = []

    private let clock: Clock
    private let finishedRemovalDelay: TimeInterval

    init(clock: Clock = SystemClock(), finishedRemovalDelay: TimeInterval = 10) {
        self.clock = clock
        self.finishedRemovalDelay = finishedRemovalDelay
    }

    func apply(_ event: HookEvent) {
        let existing = orderedSessions.firstIndex { $0.id == event.sessionId }

        if let idx = existing {
            var session = orderedSessions[idx]
            let previousState = session.state
            let newState = StateMachine.transition(from: previousState, for: event.hook)

            if newState != previousState {
                session.state = newState
                session.enteredStateAt = clock.now()
            }
            session.tty = event.tty
            session.pid = event.pid
            session.cwd = event.cwd
            if let preview = event.promptPreview {
                session.lastPromptPreview = preview
            }
            orderedSessions[idx] = session
        } else {
            let newState = StateMachine.transition(from: nil, for: event.hook)
            let session = Session(
                id: event.sessionId,
                cwd: event.cwd,
                tty: event.tty,
                pid: event.pid,
                state: newState,
                enteredStateAt: clock.now(),
                lastPromptPreview: event.promptPreview
            )
            orderedSessions.append(session)
        }
    }

    /// Called by the 1Hz tick timer (and by tests). Removes finished sessions
    /// whose `enteredStateAt + finishedRemovalDelay` has passed.
    func tickRemovalTimer() {
        let cutoff = clock.now().addingTimeInterval(-finishedRemovalDelay)
        orderedSessions.removeAll { $0.state == .finished && $0.enteredStateAt <= cutoff }
    }

    /// Mark a session finished immediately (used by the TerminalBridge stale-tab path
    /// and the StaleSessionSweeper). No-op if already finished or unknown.
    func markFinished(sessionId: String) {
        guard let idx = orderedSessions.firstIndex(where: { $0.id == sessionId }) else { return }
        guard orderedSessions[idx].state != .finished else { return }
        orderedSessions[idx].state = .finished
        orderedSessions[idx].enteredStateAt = clock.now()
    }
}
