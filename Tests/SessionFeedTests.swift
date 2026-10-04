import XCTest
@testable import ClaudeMonitor

@MainActor
final class SessionFeedTests: XCTestCase {
    private let chauffeurURL = "chauffeur://session/11111111-1111-1111-1111-111111111111/22222222-2222-2222-2222-222222222222"

    private func session(_ id: String, pid: Int32, state: SessionState = .working) -> Session {
        Session(id: id, provider: .claude, cwd: "/Users/me/\(id)", tty: "/dev/ttys001", pid: pid,
                state: state, enteredStateAt: Date(timeIntervalSince1970: 1_800_000_000),
                lastPromptPreview: "do \(id)")
    }

    func testMapsSessionsInOrderAndResolvesChauffeurURL() {
        var lookups: [String] = []
        let feed = SessionFeed(runCommand: { [chauffeurURL] _, args in
            lookups.append(args.last!)
            let env = args.last == "100" ? "claude TERM_PROGRAM=tmux CHAUFFEUR_SESSION_URL=\(chauffeurURL) HOME=/x" : "claude HOME=/x"
            return (0, env)
        }, now: { Date(timeIntervalSince1970: 1_800_000_060) })

        let snapshot = feed.snapshot(of: [session("alpha", pid: 100, state: .needsYou), session("beta", pid: 200)])

        XCTAssertEqual(snapshot.sessions.map(\.id), ["alpha", "beta"])
        XCTAssertEqual(snapshot.sessions[0].project, "alpha")
        XCTAssertEqual(snapshot.sessions[0].state, .needsYou)
        XCTAssertEqual(snapshot.sessions[0].promptPreview, "do alpha")
        XCTAssertEqual(snapshot.sessions[0].enteredStateDate, Date(timeIntervalSince1970: 1_800_000_000))
        XCTAssertEqual(snapshot.sessions[0].chauffeurURL, chauffeurURL)
        XCTAssertNil(snapshot.sessions[1].chauffeurURL)
        XCTAssertEqual(ISO8601DateFormatter().date(from: snapshot.generatedAt), Date(timeIntervalSince1970: 1_800_000_060))
        XCTAssertEqual(lookups, ["100", "200"])
    }

    func testCachesLookupsPerPid() {
        var count = 0
        let feed = SessionFeed(runCommand: { _, _ in count += 1; return (0, "claude HOME=/x") })
        _ = feed.snapshot(of: [session("a", pid: 100)])
        _ = feed.snapshot(of: [session("a", pid: 100)])
        XCTAssertEqual(count, 1)
    }

    func testRetriesFailedLookups() {
        var count = 0
        let feed = SessionFeed(runCommand: { _, _ in count += 1; return (1, "") })
        _ = feed.snapshot(of: [session("a", pid: 100)])
        _ = feed.snapshot(of: [session("a", pid: 100)])
        XCTAssertEqual(count, 2)
    }

    func testSkipsSessionsWithoutPid() {
        let feed = SessionFeed(runCommand: { _, _ in XCTFail("no lookup for pid 0"); return nil })
        XCTAssertNil(feed.snapshot(of: [session("codex", pid: 0)]).sessions[0].chauffeurURL)
    }

    func testDropsForeignURLs() {
        let feed = SessionFeed(runCommand: { _, _ in (0, "claude CHAUFFEUR_SESSION_URL=https://evil.example/x") })
        XCTAssertNil(feed.snapshot(of: [session("a", pid: 100)]).sessions[0].chauffeurURL)
    }
}
