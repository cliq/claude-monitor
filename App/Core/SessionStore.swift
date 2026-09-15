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
                                                   backgroundTasksActive: activeBackground,
                                                   notificationMessage: event.message,
                                                   sessionStartSource: event.source)

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
            if let path = event.transcriptPath { session.transcriptPath = path }
            if let preview = event.promptPreview {
                session.lastPromptPreview = preview
            }
            // Only `Stop` carries a task list. Events without one (e.g. the idle
            // Notification that keeps `.backgroundWorking`) must not zero the count.
            if newState != .backgroundWorking {
                session.backgroundTaskCount = 0
                session.backgroundTaskIDs = []
            } else if let reported = event.backgroundTasksActive {
                session.backgroundTaskCount = reported
                session.backgroundTaskIDs = Set(event.backgroundTaskIDs ?? [])
            }
            orderedSessions[idx] = session
        } else {
            let activeBackground = event.backgroundTasksActive ?? 0
            let newState = StateMachine.transition(from: nil, for: event.hook,
                                                   backgroundTasksActive: activeBackground,
                                                   notificationMessage: event.message,
                                                   sessionStartSource: event.source)
            if newState == .finished { return }
            var session = Session(
                id: event.sessionId,
                provider: event.provider,
                cwd: event.cwd,
                tty: event.tty,
                pid: event.pid,
                state: newState,
                enteredStateAt: clock.now(),
                lastPromptPreview: event.promptPreview
            )
            session.backgroundTaskCount = (newState == .backgroundWorking) ? activeBackground : 0
            session.backgroundTaskIDs = (newState == .backgroundWorking)
                ? Set(event.backgroundTaskIDs ?? []) : []
            session.transcriptPath = event.transcriptPath
            orderedSessions.append(session)
        }
    }

    /// Task cancellation can append a transcript notification without firing another hook.
    /// Only reconcile the currently tracked tasks while the main turn is stopped; a read
    /// that finishes after a new prompt or permission request must not overwrite that state.
    func completeBackgroundTasks(sessionId: String, transcriptPath: String, taskIDs: Set<String>) {
        guard let session = orderedSessions.first(where: { $0.id == sessionId }),
              session.provider == .claude, session.state == .backgroundWorking,
              session.transcriptPath == transcriptPath else { return }
        let completed = session.backgroundTaskIDs.intersection(taskIDs)
        guard !completed.isEmpty else { return }
        let remaining = session.backgroundTaskIDs.subtracting(completed)
        // An older/unrecognized task may have a count but no identity. Never infer
        // that it ended just because all the identifiable tasks have ended.
        let count = max(remaining.count, session.backgroundTaskCount - completed.count)
        apply(HookEvent(hook: .stop, sessionId: session.id, tty: session.tty,
                        pid: session.pid, cwd: session.cwd, ts: Int(clock.now().timeIntervalSince1970),
                        promptPreview: nil, toolName: nil, notificationType: nil, message: nil,
                        backgroundTasksActive: count, provider: session.provider,
                        transcriptPath: transcriptPath, backgroundTaskIDs: Array(remaining).sorted()))
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
