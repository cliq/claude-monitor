// App/Core/ClaudeSessionSeeder.swift
import Foundation

/// Rebuilds Claude Code tiles at launch from Claude Code's own per-process
/// records, `<configDir>/sessions/<pid>.json`, which it keeps current while the
/// session runs (`status` is `busy` or `idle`). That covers sessions that were
/// running before the monitor had a snapshot, or started while it was down.
///
/// `idle` doesn't say whether the session merely finished or is waiting on you:
/// Claude's idle `Notification` fires about 60s into an idle stretch, so older
/// idle sessions map to `needsYou`, like the hook-driven path would have. Only
/// interactive sessions whose exact process is still running are seeded.
struct ClaudeSessionSeeder {
    var startTime: (Int32) -> Date? = ProcessProbe.startTime(of:)
    var tty: (Int32) -> String = ProcessProbe.tty(of:)
    var now: () -> Date = Date.init

    static let idleNotificationDelay: TimeInterval = 60

    private struct Record: Decodable {
        let pid: Int32
        let sessionId: String
        let cwd: String
        let kind: String?
        let status: String?
        let statusUpdatedAt: Double?
        let procStart: String?
    }

    func sessions(configDirs: [URL]) -> [Session] {
        configDirs.flatMap { dir -> [Session] in
            let folder = dir.appendingPathComponent("sessions")
            let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
            return files.filter { $0.pathExtension == "json" }
                .sorted { $0.lastPathComponent < $1.lastPathComponent }
                .compactMap { try? Data(contentsOf: $0) }
                .compactMap { try? JSONDecoder().decode(Record.self, from: $0) }
                .compactMap(session(from:))
        }
    }

    private func session(from record: Record) -> Session? {
        guard record.kind == "interactive",
              let recordedStart = record.procStart.flatMap(Self.parseProcStart),
              let started = startTime(record.pid),
              // `procStart` has whole-second resolution; the kernel's has microseconds.
              abs(started.timeIntervalSince(recordedStart)) < 1.5 else { return nil }

        let changedAt = record.statusUpdatedAt.map { Date(timeIntervalSince1970: $0 / 1000) } ?? now()
        let state: SessionState
        switch record.status {
        case "busy": state = .working
        case "idle":
            state = now().timeIntervalSince(changedAt) >= Self.idleNotificationDelay ? .needsYou : .waiting
        default: state = .needsYou
        }
        return Session(id: record.sessionId, provider: .claude, cwd: record.cwd,
                       tty: tty(record.pid), pid: record.pid, state: state, enteredStateAt: changedAt)
    }

    /// `procStart` is `ps -o lstart` output in UTC, e.g. "Wed Sep 30 08:25:35 2026"
    /// (single-digit days are space-padded).
    static func parseProcStart(_ text: String) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "EEE MMM d HH:mm:ss yyyy"
        let normalized = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return formatter.date(from: normalized)
    }
}
