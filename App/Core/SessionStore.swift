import Foundation
import Combine

final class SessionStore: ObservableObject {
    @Published private(set) var orderedSessions: [Session] = []

    private let clock: Clock

    init(clock: Clock = SystemClock()) {
        self.clock = clock
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
            // Always refresh identity fields; they may have been captured mid-lifecycle.
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
}
