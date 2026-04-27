// App/Core/SessionStore.swift
import Foundation
import Combine

final class SessionStore: ObservableObject {
    @Published private(set) var orderedSessions: [Session] = []

    private let clock: Clock
    private let onEventApplied: (HookEvent) -> Void

    init(clock: Clock = SystemClock(),
         onEventApplied: @escaping (HookEvent) -> Void = { _ in }) {
        self.clock = clock
        self.onEventApplied = onEventApplied
    }

    func apply(_ event: HookEvent) {
        defer { onEventApplied(event) }
        let existing = orderedSessions.firstIndex { $0.id == event.sessionId }

        if let idx = existing {
            var session = orderedSessions[idx]
            let previousState = session.state
            let newState = StateMachine.transition(from: previousState, for: event.hook)

            if newState == .finished {
                orderedSessions.remove(at: idx)
                return
            }

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
            if newState == .finished { return }
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

    /// Remove a session immediately (used by the terminal focus stale-tab path
    /// and the StaleSessionSweeper). No-op if unknown.
    func markFinished(sessionId: String) {
        orderedSessions.removeAll { $0.id == sessionId }
    }

}
