// App/Core/Terminal/ChauffeurProvider.swift
import Foundation

#if canImport(AppKit)
import AppKit
#endif

/// Chauffeur runs each Claude/Codex session in a private tmux pane. It records
/// no pane ttys and has no AppleScript dictionary, so this provider ignores the
/// tty entirely: Chauffeur exports `CHAUFFEUR_SESSION_URL` (a deep link such as
/// `chauffeur://session/<projectUUID>/<sessionUUID>`) into every process it
/// launches. We read the Claude process's environment with `ps eww`, pull the
/// URL out, and hand it to Launch Services. Chauffeur then launches if needed,
/// opens the project window, selects the session, focuses its terminal, and
/// activates itself — no activation is needed on our side.
///
/// The URL is always used verbatim: debug builds register `chauffeur-debug://`
/// and rebuilding it from `CHAUFFEUR_SESSION_ID` would target the wrong app.
final class ChauffeurProvider: TerminalProvider {
    let displayName = "Chauffeur"
    let bundleID = "dev.cliq.chauffeur"

    /// Debug builds ship under a suffixed id and their own URL scheme.
    static let debugBundleID = "dev.cliq.chauffeur.debug"
    static let acceptedSchemes: Set<String> = ["chauffeur", "chauffeur-debug"]
    static let environmentKey = "CHAUFFEUR_SESSION_URL"

    typealias CommandRunner = OrcaProvider.CommandRunner
    /// Opens `url` with the default handler; returns whether the request was accepted.
    typealias URLOpener = (URL) -> Bool

    private let runCommand: CommandRunner
    private let openURL: URLOpener

    init(runCommand: @escaping CommandRunner = OrcaProvider.runProcess,
         openURL: URLOpener? = nil) {
        self.runCommand = runCommand
        self.openURL = openURL ?? { NSWorkspace.shared.open($0) }
    }

    private var bundleIDs: [String] { [bundleID, Self.debugBundleID] }

    var isInstalled: Bool {
        bundleIDs.contains { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) != nil }
    }

    func isRunning() -> Bool {
        let running = Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier))
        return bundleIDs.contains { running.contains($0) }
    }

    /// Opening the deep link launches Chauffeur, so the bridge must consult
    /// this provider even when the app is closed.
    var launchesOnFocus: Bool { true }

    func focus(tty: String, expectedPid: Int32) -> FocusResult {
        guard let ps = runCommand("/bin/ps", ["eww", "-o", "command=", "-p", String(expectedPid)]),
              ps.status == 0 else {
            return .scriptError("Could not read the session's environment")
        }
        guard let raw = Self.sessionURLString(fromEnvironmentDump: ps.stdout) else {
            return .noSuchTab
        }
        guard let url = Self.validatedSessionURL(raw) else {
            return .scriptError("Unrecognized Chauffeur session URL")
        }
        return openURL(url) ? .focused : .scriptError("Chauffeur refused to open the session")
    }

    /// Extracts `CHAUFFEUR_SESSION_URL` from a `ps eww` command+environment
    /// dump. Values are space-delimited in `ps` output; the URL never contains
    /// whitespace.
    static func sessionURLString(fromEnvironmentDump dump: String) -> String? {
        guard let range = dump.range(of: environmentKey + "=") else { return nil }
        let value = dump[range.upperBound...].prefix { !$0.isWhitespace }
        return value.isEmpty ? nil : String(value)
    }

    /// Accepts only Chauffeur's own session deep links so a leaked or
    /// tampered variable can never make us open an arbitrary URL.
    static func validatedSessionURL(_ raw: String) -> URL? {
        guard let url = URL(string: raw),
              let scheme = url.scheme?.lowercased(), acceptedSchemes.contains(scheme),
              url.host?.lowercased() == "session" else {
            return nil
        }
        return url
    }
}
