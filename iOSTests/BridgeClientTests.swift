import XCTest
@testable import ClaudeMonitorMobile

final class BridgeClientTests: XCTestCase {
    private func response(_ text: String) -> Data { Data(text.utf8) }

    func test_parsesStatusAndBody() {
        let parsed = BridgeHTTPResponse.parse(response(
            "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: 2\r\nConnection: close\r\n\r\n{}"))
        XCTAssertEqual(parsed, BridgeHTTPResponse(status: 200, body: Data("{}".utf8)))
    }

    func test_waitsForFullBody() {
        XCTAssertNil(BridgeHTTPResponse.parse(response("HTTP/1.1 200 OK\r\nContent-Length: 10\r\n\r\n{}")))
        XCTAssertNil(BridgeHTTPResponse.parse(response("HTTP/1.1 200 OK\r\nContent-Length: 2\r\n")))
    }

    func test_parsesNotFound() {
        let parsed = BridgeHTTPResponse.parse(response("HTTP/1.1 404 Not Found\r\nContent-Length: 9\r\n\r\nnot found"))
        XCTAssertEqual(parsed?.status, 404)
    }

    func test_rejectsNonHTTP() {
        XCTAssertNil(BridgeHTTPResponse.parse(response("garbage\r\n\r\n")))
    }

    func test_bridgeBodyDecodesAsSnapshot() throws {
        let json = #"{"updated_at":"2026-07-19T12:00:00Z","schema_version":2,"accounts":[{"name":"work","status":"ok","provider":"codex","metrics":[{"id":"5h","label":"5H","used_pct":12,"resets":"14:00"}]}]}"#
        let parsed = try XCTUnwrap(BridgeHTTPResponse.parse(response(
            "HTTP/1.1 200 OK\r\nContent-Length: \(json.utf8.count)\r\n\r\n\(json)")))
        let snapshot = try JSONDecoder().decode(UsageSnapshot.self, from: parsed.body)
        XCTAssertEqual(snapshot.accounts.first?.provider, .codex)
        XCTAssertEqual(snapshot.accounts.first?.displayMetrics.map(\.usedPct), [12])
    }
}

final class BridgeEndpointTests: XCTestCase {
    func test_manualParsing() {
        XCTAssertEqual(BridgeEndpoint.manual(from: " my-mac.local "), .manual(host: "my-mac.local", port: 8737))
        XCTAssertEqual(BridgeEndpoint.manual(from: "192.168.1.5:9000"), .manual(host: "192.168.1.5", port: 9000))
        XCTAssertEqual(BridgeEndpoint.manual(from: "http://192.168.1.5:8737/usage"), .manual(host: "192.168.1.5", port: 8737))
        XCTAssertNil(BridgeEndpoint.manual(from: ""))
        XCTAssertNil(BridgeEndpoint.manual(from: "host:0"))
        XCTAssertNil(BridgeEndpoint.manual(from: "host:99999"))
        XCTAssertNil(BridgeEndpoint.manual(from: ":8737"))
    }

    func test_displayNameHidesDefaultPort() {
        XCTAssertEqual(BridgeEndpoint.manual(host: "mac.local", port: 8737).displayName, "mac.local")
        XCTAssertEqual(BridgeEndpoint.manual(host: "mac.local", port: 9000).displayName, "mac.local:9000")
        XCTAssertEqual(BridgeEndpoint.bonjour(name: "Studio").displayName, "Studio")
    }

    @MainActor
    func test_storePersistsSelectedEndpoint() {
        let defaults = UserDefaults(suiteName: "BridgeEndpointTests")!
        defaults.removePersistentDomain(forName: "BridgeEndpointTests")
        defer { defaults.removePersistentDomain(forName: "BridgeEndpointTests") }

        let store = UsageStore(defaults: defaults, reloadWidgets: {})
        XCTAssertNil(store.endpoint)
        store.endpoint = .bonjour(name: "Studio")
        XCTAssertEqual(UsageStore(defaults: defaults, reloadWidgets: {}).endpoint, .bonjour(name: "Studio"))
    }
}
