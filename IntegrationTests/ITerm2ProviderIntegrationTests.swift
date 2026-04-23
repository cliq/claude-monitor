// IntegrationTests/ITerm2ProviderIntegrationTests.swift
import XCTest
import AppKit
@testable import ClaudeMonitor

final class ITerm2ProviderIntegrationTests: XCTestCase {
    private let provider = ITerm2Provider()

    override func setUpWithError() throws {
        try super.setUpWithError()
        if ProcessInfo.processInfo.environment["RUN_TERMINAL_INTEGRATION"] != "1" {
            throw XCTSkip("Set RUN_TERMINAL_INTEGRATION=1 to enable. Requires Automation permission.")
        }
        guard provider.isInstalled else {
            throw XCTSkip("iTerm2 is not installed on this machine.")
        }
    }

    func test_focusSessionByTTY() throws {
        // Open an iTerm2 window running a long-lived command, then read its tty.
        let open = """
        tell application "iTerm"
            activate
            create window with default profile
            delay 0.6
            tell current session of current window
                write text "echo READY; exec sleep 30"
                delay 0.3
                return tty
            end tell
        end tell
        """
        var err: NSDictionary?
        let descriptor = NSAppleScript(source: open)?.executeAndReturnError(&err)
        XCTAssertNil(err, "setup AppleScript failed: \(String(describing: err))")
        let tty = try XCTUnwrap(descriptor?.stringValue)

        // Open a second window so the first isn't frontmost.
        let openSecond = """
        tell application "iTerm"
            create window with default profile
            delay 0.3
            tell current session of current window to write text "echo other"
        end tell
        """
        _ = NSAppleScript(source: openSecond)?.executeAndReturnError(nil)

        let result = provider.focus(tty: tty, expectedPid: ProcessInfo.processInfo.processIdentifier)
        XCTAssertEqual(result, .focused)

        // Cleanup: close any window whose current session matches the tty.
        let cleanup = """
        tell application "iTerm"
            repeat with w in windows
                if tty of current session of w is "\(tty)" then close w
            end repeat
        end tell
        """
        _ = NSAppleScript(source: cleanup)?.executeAndReturnError(nil)
    }

    func test_focusReturnsNoSuchTabForUnknownTTY() {
        let result = provider.focus(tty: "/dev/ttys999", expectedPid: ProcessInfo.processInfo.processIdentifier)
        let isAcceptable: Bool = {
            if result == .noSuchTab { return true }
            if case .scriptError = result { return true }
            return false
        }()
        XCTAssertTrue(isAcceptable,
                      "expected noSuchTab (or scriptError if iTerm2 isn't running), got \(result)")
    }
}
