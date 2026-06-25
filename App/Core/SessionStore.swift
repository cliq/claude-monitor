// App/Core/SessionStore.swift
import Foundation
import Combine

final class SessionStore: ObservableObject {
    @Published private(set) var orderedSessions: [Session] = []
    @Published private(set) var ignoredSessionIds: Set<String> = []

    private let clock: Clock
    private let onEventApplied: (HookEvent) -> Void

    init(clock: Clock = SystemClock(),
         onEventApplied: @escaping (HookEvent) -> Void = { _ in }) {
        self.clock = clock
        self.onEventApplied = onEventApplied
    }

    /// Sessions visible in the dashboard, menu bar list, and badge aggregates.
    var visibleSessions: [Session] {
        orderedSessions.filter { !ignoredSessionIds.contains($0.id) }
    }

    /// Sessions the user has chosen to silence, in the same order as `orderedSessions`.
    var ignoredSessions: [Session] {
        orderedSessions.filter { ignoredSessionIds.contains($0.id) }
    }

    func apply(_ event: HookEvent) {
        defer { onEventApplied(event) }
        let existing = orderedSessions.firstIndex { $0.id == event.sessionId }

        if let idx = existing {
            var session = orderedSessions[idx]
            let previousState = session.state
            let activeBackground = event.backgroundTasksActive ?? 0
            let newState = StateMachine.transition(from: previousState, for: event.hook,
                                                   backgroundTasksActive: activeBackground)

            if newState == .finished {
                orderedSessions.remove(at: idx)
                ignoredSessionIds.remove(event.sessionId)
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
            session.backgroundTaskCount = (newState == .backgroundWorking) ? activeBackground : 0
            orderedSessions[idx] = session
        } else {
            let activeBackground = event.backgroundTasksActive ?? 0
            let newState = StateMachine.transition(from: nil, for: event.hook,
                                                   backgroundTasksActive: activeBackground)
            if newState == .finished { return }
            var session = Session(
                id: event.sessionId,
                cwd: event.cwd,
                tty: event.tty,
                pid: event.pid,
                state: newState,
                enteredStateAt: clock.now(),
                lastPromptPreview: event.promptPreview
            )
            session.backgroundTaskCount = (newState == .backgroundWorking) ? activeBackground : 0
            orderedSessions.append(session)
        }
    }

    /// Remove a session immediately (used by the terminal focus stale-tab path
    /// and the StaleSessionSweeper). No-op if unknown.
    func markFinished(sessionId: String) {
        orderedSessions.removeAll { $0.id == sessionId }
        ignoredSessionIds.remove(sessionId)
    }

    func ignore(sessionId: String) {
        ignoredSessionIds.insert(sessionId)
    }

    func unignore(sessionId: String) {
        ignoredSessionIds.remove(sessionId)
    }

}
