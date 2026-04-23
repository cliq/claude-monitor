import Foundation

enum StateMachine {
    /// Compute the new state given the current state (nil if unknown session) and incoming hook.
    /// Unknown sessions are synthesized as if a SessionStart had fired first.
    static func transition(from current: SessionState?, for hook: HookName) -> SessionState {
        let base = current ?? applyFromNil()
        return apply(base, hook)
    }

    private static func applyFromNil() -> SessionState {
        .waiting  // synthesized SessionStart
    }

    private static func apply(_ state: SessionState, _ hook: HookName) -> SessionState {
        if state == .finished { return .finished }
        switch hook {
        case .sessionStart:     return .waiting
        case .userPromptSubmit: return .working
        case .stop:             return .waiting
        case .notification:     return .needsYou
        case .sessionEnd:       return .finished
        }
    }
}
