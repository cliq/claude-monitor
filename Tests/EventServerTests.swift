import XCTest
@testable import ClaudeMonitor

final class EventServerTests: XCTestCase {
    func test_serverReceivesPostedEvent() async throws {
        var received: [HookEvent] = []
        let expect = expectation(description: "event received")
        let server = EventServer { event in
            received.append(event)
            expect.fulfill()
        }
        try server.start()
        defer { server.stop() }

        let port = try XCTUnwrap(server.port)
        let body = """
        {"hook":"SessionStart","session_id":"abc","tty":"/dev/ttys001","pid":1,"cwd":"/","ts":1}
        """.data(using: .utf8)!

        var req = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/event")!)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = body

        let (_, response) = try await URLSession.shared.data(for: req)
        XCTAssertEqual((response as! HTTPURLResponse).statusCode, 204)

        await fulfillment(of: [expect], timeout: 2)
        XCTAssertEqual(received.count, 1)
        XCTAssertEqual(received[0].sessionId, "abc")
    }

    func test_serverRejectsMalformedJsonWith400() async throws {
        let server = EventServer { _ in }
        try server.start()
        defer { server.stop() }

        let port = try XCTUnwrap(server.port)
        var req = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/event")!)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = "not json".data(using: .utf8)!

        let (_, response) = try await URLSession.shared.data(for: req)
        XCTAssertEqual((response as! HTTPURLResponse).statusCode, 400)
    }

    func test_serverRejectsNonPostWith405() async throws {
        let server = EventServer { _ in }
        try server.start()
        defer { server.stop() }

        let port = try XCTUnwrap(server.port)
        let req = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/event")!)

        let (_, response) = try await URLSession.shared.data(for: req)
        XCTAssertEqual((response as! HTTPURLResponse).statusCode, 405)
    }

    func test_serverRespondsToHealthCheck() async throws {
        let server = EventServer { _ in }
        try server.start()
        defer { server.stop() }

        let port = try XCTUnwrap(server.port)
        let req = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/health")!)

        let (_, response) = try await URLSession.shared.data(for: req)
        XCTAssertEqual((response as! HTTPURLResponse).statusCode, 200)
    }
}
