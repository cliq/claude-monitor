// App/Core/SessionPersistence.swift
import Foundation

/// Keeps the dashboard's sessions across app restarts (updates, crashes, quits).
///
/// The store is otherwise in-memory only, and a session reappears only when it
/// fires its next hook — a session that needs you fires nothing until you answer
/// it. Each entry records its process's start time, so a restore only brings
/// back sessions whose exact process is still running (pids are recycled).
struct SessionPersistence {
    let location: URL
    var startTime: (Int32) -> Date? = ProcessProbe.startTime(of:)
    var now: () -> Date = Date.init

    struct Snapshot: Codable {
        var version = 1
        var savedAt: Date
        var sessions: [Entry]
        var ignoredSessionIds: [String]

        struct Entry: Codable {
            var session: Session
            var processStartedAt: Date
        }
    }

    struct Restored: Equatable {
        var sessions: [Session] = []
        var ignoredSessionIds: Set<String> = []
        var savedAt: Date?
    }

    /// Default location: `~/.claude-monitor/sessions.json`.
    static var defaultLocation: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude-monitor/sessions.json")
    }

    /// Sessions without a live, identifiable process are left out: they could
    /// never be swept, and today a restart is the only thing that clears them.
    func save(sessions: [Session], ignoredSessionIds: Set<String>) throws {
        let entries = sessions.compactMap { session in
            startTime(session.pid).map { Snapshot.Entry(session: session, processStartedAt: $0) }
        }
        let kept = Set(entries.map(\.session.id))
        let snapshot = Snapshot(savedAt: now(), sessions: entries,
                                ignoredSessionIds: ignoredSessionIds.filter(kept.contains).sorted())
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try FileManager.default.createDirectory(at: location.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try encoder.encode(snapshot).write(to: location, options: .atomic)
    }

    /// A missing, unreadable, or older-schema file restores nothing.
    func load() -> Restored {
        guard let data = try? Data(contentsOf: location) else { return Restored() }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let snapshot = try? decoder.decode(Snapshot.self, from: data),
              snapshot.version == 1 else { return Restored() }
        let live = snapshot.sessions.filter { entry in
            guard let started = startTime(entry.session.pid) else { return false }
            return abs(started.timeIntervalSince(entry.processStartedAt)) < 1
        }.map(\.session)
        let ids = Set(live.map(\.id))
        return Restored(sessions: live,
                        ignoredSessionIds: Set(snapshot.ignoredSessionIds).intersection(ids),
                        savedAt: snapshot.savedAt)
    }

    /// Combines the snapshot with sessions seeded from the agents' own records.
    /// A seeded session the snapshot lacks is added; one whose state changed
    /// after the snapshot was saved (the app was down) takes the seeded state.
    static func merge(restored: Restored, seeded: [Session]) -> [Session] {
        var sessions = restored.sessions
        for seed in seeded {
            if let idx = sessions.firstIndex(where: { $0.id == seed.id }) {
                guard let savedAt = restored.savedAt, seed.enteredStateAt > savedAt,
                      seed.state != sessions[idx].state else { continue }
                sessions[idx].state = seed.state
                sessions[idx].enteredStateAt = seed.enteredStateAt
                sessions[idx].backgroundTaskCount = 0
                sessions[idx].backgroundTaskIDs = []
            } else {
                sessions.append(seed)
            }
        }
        return sessions
    }
}
