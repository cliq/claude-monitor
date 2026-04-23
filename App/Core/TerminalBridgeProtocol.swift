import Foundation

enum FocusResult: Equatable {
    case focused
    case noSuchTab
    case terminalNotRunning
    case scriptError(String)
}

protocol TerminalBridgeProtocol {
    /// Focus the Terminal.app tab whose `tty` matches the argument. Also verify that
    /// a process with `expectedPid` is listed under that tab (TTY-reuse guard).
    func focus(tty: String, expectedPid: Int32) -> FocusResult
}

/// Test double. Behavior is scripted via a closure.
final class FakeTerminalBridge: TerminalBridgeProtocol {
    var handler: (String, Int32) -> FocusResult = { _, _ in .focused }
    func focus(tty: String, expectedPid: Int32) -> FocusResult {
        handler(tty, expectedPid)
    }
}
