import XCTest
@testable import ClaudeMonitor

final class TerminalBridgeIntegrationTests: XCTestCase {
    override func setUpWithError() throws {
        try super.setUpWithError()
        if ProcessInfo.processInfo.environment["RUN_TERMINAL_INTEGRATION"] != "1" {
            throw XCTSkip("Set RUN_TERMINAL_INTEGRATION=1 to enable. Requires Automation permission.")
        }
    }

    func test_focusTabByTTY() throws {
        // Open a Terminal tab running a long-lived command; capture its tty.
        let open = """
        tell application "Terminal"
            activate
            set newTab to do script "echo READY; exec sleep 30"
            delay 0.6
            return tty of newTab
        end tell
        """
        var err: NSDictionary?
        let descriptor = NSAppleScript(source: open)?.executeAndReturnError(&err)
        XCTAssertNil(err, "setup AppleScript failed: \(String(describing: err))")
        let tty = try XCTUnwrap(descriptor?.stringValue)

        // Open a second tab so the first isn't frontmost.
        let openSecond = #"tell application "Terminal" to do script "echo other""#
        _ = NSAppleScript(source: openSecond)?.executeAndReturnError(nil)

        // Exercise the bridge. Use the test-runner's own pid as `expectedPid` —
        // it's definitely alive, so the Swift-side kill(pid,0) guard passes.
        let bridge = TerminalBridge()
        let result = bridge.focus(tty: tty, expectedPid: ProcessInfo.processInfo.processIdentifier)
        XCTAssertEqual(result, .focused)

        // Cleanup: close the tab by tty.
        let cleanup = """
        tell application "Terminal"
            close (every window whose tty of selected tab is "\(tty)")
        end tell
        """
        _ = NSAppleScript(source: cleanup)?.executeAndReturnError(nil)
    }

    func test_focusReturnsNoSuchTabWhenPidIsDead() {
        // Any pid that can't possibly be alive.
        let result = TerminalBridge().focus(tty: "/dev/ttys999", expectedPid: 2_147_483_000)
        // Either Terminal-not-running or noSuchTab is acceptable; both are "don't focus".
        XCTAssertTrue(result == .noSuchTab || result == .terminalNotRunning,
                      "expected noSuchTab or terminalNotRunning, got \(result)")
    }
}
