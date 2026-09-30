// Tests/SessionPersistenceTests.swift
import XCTest
@testable import ClaudeMonitor

final class SessionPersistenceTests: XCTestCase {
    private var dir: URL!
    private let t0 = Date(timeIntervalSince1970: 1_790_000_000)

    override func setUpWithError() throws {
        dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("claude-monitor-persistence-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    private func session(_ id: String, pid: Int32, state: SessionState = .needsYou,
                         at date: Date? = nil) -> Session {
        Session(id: id, provider: .claude, cwd: "/Users/leo/\(id)", tty: "/dev/ttys00\(pid % 10)",
                pid: pid, state: state, enteredStateAt: date ?? t0, lastPromptPreview: "prompt \(id)")
    }

    private func persistence(starts: [Int32: Date]) -> SessionPersistence {
        var p = SessionPersistence(location: dir.appendingPathComponent("sessions.json"))
        p.startTime = { starts[$0] }
        p.now = { self.t0.addingTimeInterval(100) }
        return p
    }

    // MARK: Snapshot

    func test_roundTripKeepsStateTimerAndPreview() throws {
        var s = session("a", pid: 11, state: .backgroundWorking)
        s.backgroundTaskCount = 2
        s.backgroundTaskIDs = ["t1", "t2"]
        s.transcriptPath = "/tmp/a.jsonl"
        let p = persistence(starts: [11: t0])
        try p.save(sessions: [s], ignoredSessionIds: ["a"])

        let restored = p.load()
        XCTAssertEqual(restored.sessions, [s])
        XCTAssertEqual(restored.ignoredSessionIds, ["a"])
        XCTAssertEqual(restored.savedAt, t0.addingTimeInterval(100))
    }

    func test_loadDropsSessionsWhoseProcessExitedOrPidWasRecycled() throws {
        try persistence(starts: [11: t0, 12: t0, 13: t0])
            .save(sessions: [session("alive", pid: 11), session("gone", pid: 12), session("recycled", pid: 13)],
                  ignoredSessionIds: ["gone"])

        let restored = persistence(starts: [11: t0, 13: t0.addingTimeInterval(30)]).load()
        XCTAssertEqual(restored.sessions.map(\.id), ["alive"])
        XCTAssertEqual(restored.ignoredSessionIds, [], "ignore marks only survive with their session")
    }

    func test_saveSkipsSessionsWithoutAnIdentifiableProcess() throws {
        let p = persistence(starts: [11: t0])
        try p.save(sessions: [session("codex:ambiguous", pid: 0), session("a", pid: 11)],
                   ignoredSessionIds: [])
        XCTAssertEqual(p.load().sessions.map(\.id), ["a"])
    }

    func test_missingOrCorruptFileRestoresNothing() throws {
        let p = persistence(starts: [:])
        XCTAssertEqual(p.load(), SessionPersistence.Restored())
        try Data("not json".utf8).write(to: p.location)
        XCTAssertEqual(p.load(), SessionPersistence.Restored())
    }

    // MARK: Merge

    func test_mergeAddsSeededSessionsTheSnapshotLacks() {
        let restored = SessionPersistence.Restored(sessions: [session("a", pid: 11)], savedAt: t0)
        let merged = SessionPersistence.merge(restored: restored, seeded: [session("b", pid: 12, state: .working)])
        XCTAssertEqual(merged.map(\.id), ["a", "b"])
    }

    func test_mergeTakesSeededStateOnlyWhenItChangedAfterTheSnapshot() {
        let snap = session("a", pid: 11, state: .working, at: t0)
        let restored = SessionPersistence.Restored(sessions: [snap], savedAt: t0.addingTimeInterval(10))

        let before = session("a", pid: 11, state: .needsYou, at: t0.addingTimeInterval(5))
        XCTAssertEqual(SessionPersistence.merge(restored: restored, seeded: [before]), [snap])

        let after = session("a", pid: 11, state: .needsYou, at: t0.addingTimeInterval(60))
        let merged = SessionPersistence.merge(restored: restored, seeded: [after])
        XCTAssertEqual(merged.first?.state, .needsYou)
        XCTAssertEqual(merged.first?.enteredStateAt, t0.addingTimeInterval(60))
        XCTAssertEqual(merged.first?.lastPromptPreview, "prompt a", "snapshot details are kept")
    }

    // MARK: Store

    func test_restoreKeepsStateAndNeverReplacesALiveSession() {
        let store = SessionStore(clock: FakeClock())
        store.apply(HookEvent(hook: .userPromptSubmit, sessionId: "a", tty: "", pid: 11, cwd: "/a",
                              ts: 0, promptPreview: "live", toolName: nil, notificationType: nil, message: nil))
        store.restore([session("a", pid: 11), session("b", pid: 12)], ignoredSessionIds: ["a", "b"])

        XCTAssertEqual(store.orderedSessions.map(\.id), ["a", "b"])
        XCTAssertEqual(store.orderedSessions[0].state, .working)
        XCTAssertEqual(store.orderedSessions[1].state, .needsYou, "no state-machine reset to waiting")
        XCTAssertEqual(store.ignoredSessionIds, ["b"])
    }
}

final class ClaudeSessionSeederTests: XCTestCase {
    private var configDir: URL!
    private let now = Date(timeIntervalSince1970: 1_790_764_000)
    private let procStart = "Wed Sep 30 08:25:35 2026"
    private var started: Date { ClaudeSessionSeeder.parseProcStart(procStart)! }

    override func setUpWithError() throws {
        configDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("claude-monitor-seeder-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: configDir.appendingPathComponent("sessions"),
                                                withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: configDir)
    }

    private func write(pid: Int32, status: String, idleFor seconds: TimeInterval = 0,
                       kind: String = "interactive", procStart: String? = nil) throws {
        let record: [String: Any] = [
            "pid": pid, "sessionId": "S\(pid)", "cwd": "/Users/leo/p\(pid)", "kind": kind,
            "status": status, "statusUpdatedAt": (now.timeIntervalSince1970 - seconds) * 1000,
            "procStart": procStart ?? self.procStart,
        ]
        try JSONSerialization.data(withJSONObject: record)
            .write(to: configDir.appendingPathComponent("sessions/\(pid).json"))
        try Data("key".utf8).write(to: configDir.appendingPathComponent("sessions/\(pid).abc.key"))
    }

    private func seed(alive: Set<Int32>) -> [Session] {
        var seeder = ClaudeSessionSeeder()
        seeder.startTime = { alive.contains($0) ? self.started.addingTimeInterval(0.4) : nil }
        seeder.tty = { "/dev/ttys\($0)" }
        seeder.now = { self.now }
        return seeder.sessions(configDirs: [configDir])
    }

    func test_mapsClaudeStatusToDashboardState() throws {
        try write(pid: 1, status: "busy")
        try write(pid: 2, status: "idle", idleFor: 300)
        try write(pid: 3, status: "idle", idleFor: 10)

        let sessions = seed(alive: [1, 2, 3])
        XCTAssertEqual(sessions.map(\.state), [.working, .needsYou, .waiting])
        XCTAssertEqual(sessions[1].id, "S2")
        XCTAssertEqual(sessions[1].cwd, "/Users/leo/p2")
        XCTAssertEqual(sessions[1].tty, "/dev/ttys2")
        XCTAssertEqual(sessions[1].enteredStateAt, now.addingTimeInterval(-300))
    }

    func test_skipsDeadRecycledAndNonInteractiveSessions() throws {
        try write(pid: 1, status: "idle")
        try write(pid: 2, status: "idle")
        try write(pid: 3, status: "idle", procStart: "Tue Sep 29 08:25:35 2026")
        try write(pid: 4, status: "idle", kind: "background")

        XCTAssertEqual(seed(alive: [1, 3, 4]).map(\.id), ["S1"])
    }

    func test_parsesSpacePaddedProcStartAsUTC() {
        let date = ClaudeSessionSeeder.parseProcStart("Thu Oct  1 09:05:07 2026")
        XCTAssertEqual(date?.timeIntervalSince1970, 1_790_845_507)
    }
}

final class ProcessProbeTests: XCTestCase {
    func test_startTimeMatchesPsForALiveProcessAndIsNilForNone() throws {
        let ps = Process()
        ps.executableURL = URL(fileURLWithPath: "/bin/ps")
        ps.arguments = ["-o", "lstart=", "-p", String(getpid())]
        ps.environment = ["TZ": "UTC"]
        let out = Pipe()
        ps.standardOutput = out
        try ps.run()
        ps.waitUntilExit()
        let text = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)

        let expected = try XCTUnwrap(ClaudeSessionSeeder.parseProcStart(text))
        let started = try XCTUnwrap(ProcessProbe.startTime(of: getpid()))
        XCTAssertLessThan(abs(started.timeIntervalSince(expected)), 1.5)
        XCTAssertNil(ProcessProbe.startTime(of: 0))
        XCTAssertNil(ProcessProbe.startTime(of: 99_999_999))
    }
}
