// App/Core/SessionFeed.swift
import Foundation

/// Builds the `GET /sessions` snapshot the LAN bridge serves to the iOS app
/// from the dashboard's visible sessions. Main-actor only, like `SessionStore`.
///
/// Chauffeur deep links come from each agent process's environment
/// (`ChauffeurProvider`'s `ps eww` lookup). A process's environment never
/// changes, so the result is cached per pid and the phone's frequent polls
/// only pay for sessions that are new since the last one.
@MainActor
final class SessionFeed {
    typealias CommandRunner = ChauffeurProvider.CommandRunner

    private let runCommand: CommandRunner
    private let now: () -> Date
    /// pid → validated Chauffeur URL, or nil when the process has none.
    private var chauffeurURLs: [Int32: String?] = [:]

    init(runCommand: @escaping CommandRunner = OrcaProvider.runProcess,
         now: @escaping () -> Date = Date.init) {
        self.runCommand = runCommand
        self.now = now
    }

    func snapshot(of sessions: [Session]) -> SessionsSnapshot {
        let livePids = Set(sessions.map(\.pid))
        chauffeurURLs = chauffeurURLs.filter { livePids.contains($0.key) }
        let formatter = ISO8601DateFormatter()
        let remote = sessions.map { session in
            RemoteSession(id: session.id, provider: session.provider, project: session.projectName,
                          cwd: session.cwd, state: session.state,
                          enteredStateAt: formatter.string(from: session.enteredStateAt),
                          promptPreview: session.lastPromptPreview,
                          backgroundTaskCount: session.backgroundTaskCount,
                          chauffeurURL: chauffeurURL(pid: session.pid))
        }
        return SessionsSnapshot(generatedAt: formatter.string(from: now()), sessions: remote)
    }

    /// Codex sessions behind a shared app-server daemon report `pid: 0`
    /// (see `codex-hook.sh`); those have no process to read.
    private func chauffeurURL(pid: Int32) -> String? {
        guard pid > 0 else { return nil }
        if let cached = chauffeurURLs[pid] { return cached }
        // A failed `ps` isn't cached: the next poll retries it.
        guard let ps = runCommand("/bin/ps", ["eww", "-o", "command=", "-p", String(pid)]),
              ps.status == 0 else { return nil }
        let url = ChauffeurProvider.sessionURLString(fromEnvironmentDump: ps.stdout)
            .flatMap(ChauffeurProvider.validatedSessionURL)?.absoluteString
        chauffeurURLs[pid] = .some(url)
        return url
    }
}
