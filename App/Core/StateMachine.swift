import Foundation

enum StateMachine {
    /// Compute the new state given the current state (nil if unknown session) and incoming hook.
    /// Unknown sessions are synthesized as if a SessionStart had fired first.
    /// `backgroundTasksActive` is the count of still-running background tasks reported by the
    /// `Stop` hook payload; it only influences the `.stop` transition.
    static func transition(from current: SessionState?,
                           for hook: HookName,
                           backgroundTasksActive: Int = 0) -> SessionState {
        let base = current ?? applyFromNil()
        return apply(base, hook, backgroundTasksActive)
    }

    private static func applyFromNil() -> SessionState {
        .waiting  // synthesized SessionStart
    }

    private static func apply(_ state: SessionState,
                              _ hook: HookName,
                              _ backgroundTasksActive: Int) -> SessionState {
        if state == .finished { return .finished }
        switch hook {
        case .sessionStart:     return .waiting
        case .userPromptSubmit: return .working
        case .stop:             return backgroundTasksActive > 0 ? .backgroundWorking : .waiting
        case .notification:     return .needsYou
        case .sessionEnd:       return .finished
        }
    }
}
