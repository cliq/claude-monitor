import Foundation

enum FocusResult: Equatable {
    case focused
    case noSuchTab
    case terminalNotRunning
    case scriptError(String)
}

protocol TerminalBridgeProtocol {
    /// Focus the terminal tab whose `tty` matches. `expectedPid` is used by
    /// the implementation as part of a TTY-reuse guard (see CompositeTerminalBridge).
    func focus(tty: String, expectedPid: Int32) -> FocusResult
}
