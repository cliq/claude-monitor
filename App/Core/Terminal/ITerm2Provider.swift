// App/Core/Terminal/ITerm2Provider.swift
import Foundation

#if canImport(AppKit)
import AppKit
#endif

final class ITerm2Provider: TerminalProvider {
    let displayName = "iTerm2"
    let bundleID = "com.googlecode.iterm2"

    var isInstalled: Bool {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) != nil
    }

    func isRunning() -> Bool {
        NSWorkspace.shared.runningApplications
            .contains { $0.bundleIdentifier == bundleID }
    }

    func focus(tty: String, expectedPid: Int32) -> FocusResult {
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
        tell application "iTerm"
            if not running then return "no-such-tab"
            repeat with w in windows
                repeat with t in tabs of w
                    repeat with s in sessions of t
                        if tty of s is "\(safeTty)" then
                            select s
                            tell t to select
                            set index of w to 1
                            activate
                            return "focused"
                        end if
                    end repeat
                end repeat
            end repeat
            return "no-such-tab"
        end tell
        """
    }
}
