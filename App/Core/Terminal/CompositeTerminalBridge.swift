// App/Core/Terminal/CompositeTerminalBridge.swift
import Foundation
import Darwin

/// Fans `focus(tty:expectedPid:)` out across a list of `TerminalProvider`s
/// and returns on the first `.focused`. Non-running providers are skipped.
final class CompositeTerminalBridge: TerminalBridgeProtocol {
    private let providers: [TerminalProvider]
    private let isDisabled: (String) -> Bool

    /// - Parameters:
    ///   - providers: Ordered list. First `.focused` wins.
    ///   - isDisabled: Given a bundle ID, returns true if the user has opted it out.
    init(providers: [TerminalProvider],
         isDisabled: @escaping (String) -> Bool) {
        self.providers = providers
        self.isDisabled = isDisabled
    }

    func focus(tty: String, expectedPid: Int32) -> FocusResult {
        let enabled = providers.filter { !isDisabled($0.bundleID) }
        if enabled.isEmpty { return .terminalNotRunning }

        // `kill(pid, 0)` returns 0 if the process exists. ESRCH means really gone;
        // EPERM means alive but owned elsewhere. Only ESRCH is a stale session.
        if kill(expectedPid, 0) != 0 && errno == ESRCH { return .noSuchTab }

        let running = enabled.filter { $0.isRunning() }
        if running.isEmpty { return .terminalNotRunning }

        var lastError: FocusResult?
        for provider in running {
            let result = provider.focus(tty: tty, expectedPid: expectedPid)
            switch result {
            case .focused:
                return .focused
            case .scriptError:
                lastError = result
            case .noSuchTab, .terminalNotRunning:
                continue
            }
        }
        return lastError ?? .noSuchTab
    }
}
