// App/Core/Terminal/TerminalRegistry.swift
import Foundation

/// The hardcoded list of terminal apps Claude Monitor knows how to drive.
/// Order is probe order in `CompositeTerminalBridge`.
///
/// To add another terminal: implement a `TerminalProvider` and add it to `all`.
enum TerminalRegistry {
    static let all: [TerminalProvider] = [
        // Chauffeur goes first: its sessions are identified by an environment
        // variable, so they must be claimed before the AppleScript providers
        // scan ttys (Chauffeur reuses ttys inside tmux).
        ChauffeurProvider(),
        AppleTerminalProvider(),
        ITerm2Provider(),
        OrcaProvider(),
    ]

    static func installed() -> [TerminalProvider] {
        all.filter { $0.isInstalled }
    }
}
