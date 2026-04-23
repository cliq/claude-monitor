import XCTest
@testable import ClaudeMonitor

final class TerminalBridgeIntegrationTests: XCTestCase {
    private let provider = AppleTerminalProvider()

    override func setUpWithError() throws {
        try super.setUpWithError()
        if ProcessInfo.processInfo.environment["RUN_TERMINAL_INTEGRATION"] != "1" {
            throw XCTSkip("Set RUN_TERMINAL_INTEGRATION=1 to enable. Requires Automation permission.")
        }
    }

    func test_focusTabByTTY() throws {
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

        let openSecond = #"tell application "Terminal" to do script "echo other""#
        _ = NSAppleScript(source: openSecond)?.executeAndReturnError(nil)

        let result = provider.focus(tty: tty, expectedPid: ProcessInfo.processInfo.processIdentifier)
        XCTAssertEqual(result, .focused)

        let cleanup = """
        tell application "Terminal"
            close (every window whose tty of selected tab is "\(tty)")
        end tell
        """
        _ = NSAppleScript(source: cleanup)?.executeAndReturnError(nil)
    }

    func test_focusReturnsNoSuchTabForUnknownTTY() {
        let result = AppleTerminalProvider().focus(tty: "/dev/ttys999",
                                                    expectedPid: ProcessInfo.processInfo.processIdentifier)
        let isAcceptable: Bool = {
            if result == .noSuchTab { return true }
            if case .scriptError = result { return true }
            return false
        }()
        XCTAssertTrue(isAcceptable,
                      "expected noSuchTab (or scriptError if Terminal isn't running), got \(result)")
    }
}
