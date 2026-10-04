import XCTest
@testable import ClaudeMonitorMobile

@MainActor
final class SessionsStoreTests: XCTestCase {
    func test_decodesBridgeSessions() throws {
        let json = #"{"generated_at":"2026-10-04T12:00:00Z","sessions":[{"id":"codex:1","provider":"codex","project":"repo","cwd":"/r","state":"backgroundWorking","entered_state_at":"2026-10-04T11:58:00Z","background_task_count":2,"chauffeur_url":"chauffeur-debug://session/A/B"}]}"#
        let snapshot = try JSONDecoder().decode(SessionsSnapshot.self, from: Data(json.utf8))
        let session = try XCTUnwrap(snapshot.sessions.first)
        XCTAssertEqual(session.provider, .codex)
        XCTAssertEqual(session.state, .backgroundWorking)
        XCTAssertNil(session.promptPreview)
        XCTAssertEqual(session.statusLine(elapsed: 125), "Working · 2 tasks · 2:05")
        XCTAssertEqual(session.chauffeurSessionURL?.absoluteString, "chauffeur-debug://session/A/B")
    }

    func test_unknownProviderAndStateStillDecode() throws {
        let json = #"{"id":"x","provider":"future","project":"p","state":"dreaming","entered_state_at":"2026-10-04T11:58:00Z"}"#
        let session = try JSONDecoder().decode(RemoteSession.self, from: Data(json.utf8))
        XCTAssertEqual(session.provider, .claude)
        XCTAssertEqual(session.state, .waiting)
        XCTAssertEqual(session.cwd, "")
    }

    func test_onlyChauffeurSessionLinksOpen() {
        func link(_ raw: String?) -> URL? {
            RemoteSession(id: "x", project: "p", cwd: "", state: .working, enteredStateAt: "", chauffeurURL: raw)
                .chauffeurSessionURL
        }
        XCTAssertNotNil(link("chauffeur://session/A/B"))
        XCTAssertNil(link(nil))
        XCTAssertNil(link("https://session/A/B"))
        XCTAssertNil(link("chauffeur://settings/A/B"))
    }

    func test_elapsedCorrectsForMacClockOffset() async {
        // The Mac's clock runs 60s behind the phone's.
        let macNow = Date().addingTimeInterval(-60)
        let iso = ISO8601DateFormatter()
        let session = RemoteSession(id: "x", project: "p", cwd: "", state: .working,
                                    enteredStateAt: iso.string(from: macNow.addingTimeInterval(-30)))
        let store = SessionsStore(endpoint: .manual(host: "mac", port: 8737)) { _ in
            SessionsSnapshot(generatedAt: iso.string(from: macNow), sessions: [session])
        }
        await store.refresh()
        XCTAssertEqual(store.snapshot?.sessions, [session])
        XCTAssertEqual(store.elapsed(session, now: Date()), 30, accuracy: 2)
    }

    func test_switchingMacClearsSessions() async {
        let store = SessionsStore(endpoint: .manual(host: "a", port: 8737)) { _ in
            SessionsSnapshot(generatedAt: "2026-10-04T12:00:00Z", sessions: [])
        }
        await store.refresh()
        XCTAssertNotNil(store.snapshot)
        store.endpoint = .manual(host: "b", port: 8737)
        XCTAssertNil(store.snapshot)
    }

    func test_reportsMacsWithoutSessionFeed() async {
        let store = SessionsStore(endpoint: .manual(host: "a", port: 8737)) { _ in throw SessionsError.unsupportedMac }
        await store.refresh()
        XCTAssertEqual(store.errorMessage, SessionsError.unsupportedMac.errorDescription)
    }
}
