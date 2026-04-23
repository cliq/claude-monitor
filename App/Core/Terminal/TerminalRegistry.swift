// App/Core/Terminal/TerminalRegistry.swift
import Foundation

/// The hardcoded list of terminal apps Claude Monitor knows how to drive.
/// Order is probe order in `CompositeTerminalBridge`.
///
/// To add another terminal: implement a `TerminalProvider` and add it to `all`.
enum TerminalRegistry {
    static let all: [TerminalProvider] = [
        AppleTerminalProvider(),
        ITerm2Provider(),
    ]

    static func installed() -> [TerminalProvider] {
        all.filter { $0.isInstalled }
    }
}
