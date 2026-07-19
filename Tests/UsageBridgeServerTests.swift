import XCTest
@testable import ClaudeMonitor

final class UsageBridgeServerTests: XCTestCase {
    private func makeServer(displayOn: Bool = true) throws -> UsageBridgeServer {
        var account = AccountUsage(name: "personal", status: "ok")
        account.sessionPct = 43
        let snapshot = UsageSnapshot(updatedAt: "2026-07-19T12:00:00Z", accounts: [account])
        let server = UsageBridgeServer(snapshot: { snapshot }, display: { displayOn })
        try server.start(port: 0) // ephemeral port for tests
        return server
    }

    private func get(_ path: String, port: UInt16) async throws -> (Int, Data) {
        let url = URL(string: "http://127.0.0.1:\(port)\(path)")!
        let (data, response) = try await URLSession.shared.data(from: url)
        return ((response as! HTTPURLResponse).statusCode, data)
    }

    func test_usageEndpointServesSnapshotJSON() async throws {
        let server = try makeServer()
        defer { server.stop() }
        let port = try XCTUnwrap(server.port)

        let (status, data) = try await get("/usage", port: port)
        XCTAssertEqual(status, 200)
        let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        XCTAssertEqual(json["updated_at"] as? String, "2026-07-19T12:00:00Z")
        let accounts = json["accounts"] as! [[String: Any]]
        XCTAssertEqual(accounts[0]["name"] as? String, "personal")
        XCTAssertEqual(accounts[0]["session_pct"] as? Int, 43)
    }

    func test_usageEndpointToleratesTrailingSlash() async throws {
        let server = try makeServer()
        defer { server.stop() }
        let port = try XCTUnwrap(server.port)

        let (status, _) = try await get("/usage/", port: port)
        XCTAssertEqual(status, 200)
    }

    func test_displayEndpointReflectsDisplayState() async throws {
        let onServer = try makeServer(displayOn: true)
        defer { onServer.stop() }
        let (_, onBody) = try await get("/display", port: try XCTUnwrap(onServer.port))
        XCTAssertEqual(String(data: onBody, encoding: .utf8), "on")

        let offServer = try makeServer(displayOn: false)
        defer { offServer.stop() }
        let (_, offBody) = try await get("/display", port: try XCTUnwrap(offServer.port))
        XCTAssertEqual(String(data: offBody, encoding: .utf8), "off")
    }

    func test_unknownPathIs404() async throws {
        let server = try makeServer()
        defer { server.stop() }
        let (status, _) = try await get("/nope", port: try XCTUnwrap(server.port))
        XCTAssertEqual(status, 404)
    }
}
