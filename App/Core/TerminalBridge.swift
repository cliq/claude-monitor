import Foundation
import Darwin

#if canImport(AppKit)
import AppKit
#endif

final class TerminalBridge: TerminalBridgeProtocol {
    func focus(tty: String, expectedPid: Int32) -> FocusResult {
        // 1. Is Terminal even running?
        let runningApps = NSWorkspace.shared.runningApplications
        guard runningApps.contains(where: { $0.bundleIdentifier == "com.apple.Terminal" }) else {
            return .terminalNotRunning
        }

        // 2. Swift-side pid liveness check (part of the TTY-reuse guard).
        //    `kill(pid, 0)` returns 0 if the process exists and we may signal it. On
        //    failure, errno distinguishes ESRCH (really gone) from EPERM (alive, but
        //    owned elsewhere). Only ESRCH means the session is stale.
        if kill(expectedPid, 0) != 0 && errno == ESRCH {
            return .noSuchTab
        }

        // 3. Run AppleScript. Result strings: "focused" or "no-such-tab".
        //    Terminal.app's `processes of t` returns a list of process *names* (strings),
        //    not descriptors — so we can't do a pid match in AppleScript. The Swift-side
        //    kill(pid, 0) above is the guard.
        let script = Self.buildScript(tty: tty)
        var errorInfo: NSDictionary?
        let appleScript = NSAppleScript(source: script)
        let descriptor = appleScript?.executeAndReturnError(&errorInfo)

        if let err = errorInfo {
            let msg = err[NSAppleScript.errorMessage] as? String ?? "unknown"
            return .scriptError(msg)
        }
        guard let result = descriptor?.stringValue else {
            return .scriptError("no result string")
        }
        switch result {
        case "focused":      return .focused
        case "no-such-tab":  return .noSuchTab
        default:
            return .scriptError(result)
        }
    }

    private static func buildScript(tty: String) -> String {
        // Escape double quotes in tty (unlikely, but be safe).
        let safeTty = tty.replacingOccurrences(of: "\"", with: "\\\"")
        return """
        tell application "Terminal"
            if not running then return "no-such-tab"
            repeat with w in windows
                repeat with t in tabs of w
                    if tty of t is "\(safeTty)" then
                        set selected of t to true
                        set index of w to 1
                        activate
                        return "focused"
                    end if
                end repeat
            end repeat
            return "no-such-tab"
        end tell
        """
    }
}
