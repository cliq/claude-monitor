import Foundation

enum StateMachine {
    /// Compute the new state given the current state (nil if unknown session) and incoming hook.
    /// Unknown sessions are synthesized as if a SessionStart had fired first.
    /// `backgroundTasksActive` is the count of still-running background tasks reported by the
    /// `Stop` hook payload; it only influences the `.stop` transition.
    /// `notificationMessage` is the `Notification` hook's message text; it lets us tell an idle
    /// "waiting for your input" ping apart from a real permission prompt.
    static func transition(from current: SessionState?,
                           for hook: HookName,
                           backgroundTasksActive: Int = 0,
                           notificationMessage: String? = nil) -> SessionState {
        let base = current ?? applyFromNil()
        return apply(base, hook, backgroundTasksActive, notificationMessage)
    }

    private static func applyFromNil() -> SessionState {
        .waiting  // synthesized SessionStart
    }

    private static func apply(_ state: SessionState,
                              _ hook: HookName,
                              _ backgroundTasksActive: Int,
                              _ notificationMessage: String?) -> SessionState {
        if state == .finished { return .finished }
        switch hook {
        case .sessionStart:     return .waiting
        case .userPromptSubmit: return .working
        case .stop:             return backgroundTasksActive > 0 ? .backgroundWorking : .waiting
        case .notification:     return notificationState(from: state, message: notificationMessage)
        case .sessionEnd:       return .finished
        }
    }

    /// A `Notification` fired while the agent is mid-turn (working or parked on a background
    /// subagent) and the message is just the idle "waiting for your input" ping is a false alarm:
    /// keep the active state instead of flipping to `needsYou`. Permission prompts and idle pings
    /// once the turn is already done still escalate.
    private static func notificationState(from state: SessionState, message: String?) -> SessionState {
        let isActive = state == .working || state == .backgroundWorking
        if isActive && isWaitingForInput(message) { return state }
        return .needsYou
    }

    private static func isWaitingForInput(_ message: String?) -> Bool {
        guard let message else { return false }
        return message.lowercased().contains("waiting for your input")
    }
}
