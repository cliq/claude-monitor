// App/Core/Terminal/AppleTerminalProvider.swift
import Foundation

#if canImport(AppKit)
import AppKit
#endif

final class AppleTerminalProvider: TerminalProvider {
    let displayName = "Terminal"
    let bundleID = "com.apple.Terminal"

    var isInstalled: Bool {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) != nil
    }

    func isRunning() -> Bool {
        NSWorkspace.shared.runningApplications
            .contains { $0.bundleIdentifier == bundleID }
    }

    func focus(tty: String, expectedPid: Int32) -> FocusResult {
        // `expectedPid` is consumed upstream by `CompositeTerminalBridge` (kill/ESRCH).
        // Terminal.app's AppleScript dictionary exposes `processes of t` as strings,
        // not process descriptors, so we can't re-verify the pid here even if we wanted to.
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
        case "focused":     return .focused
        case "no-such-tab": return .noSuchTab
        default:            return .scriptError(result)
        }
    }

    private static func buildScript(tty: String) -> String {
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
