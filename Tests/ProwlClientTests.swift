import XCTest
@testable import ClaudeMonitor

final class ProwlClientTests: XCTestCase {
    override func setUp() {
        super.setUp()
        URLProtocolStub.reset()
    }
    override func tearDown() {
        URLProtocolStub.reset()
        super.tearDown()
    }

    private func makeClient() -> ProwlClient {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.protocolClasses = [URLProtocolStub.self]
        return ProwlClient(session: URLSession(configuration: cfg))
    }

    func test_sendBuildsExpectedRequest() async throws {
        URLProtocolStub.responder = { req in
            XCTAssertEqual(req.url?.absoluteString, "https://api.prowlapp.com/publicapi/add")
            XCTAssertEqual(req.httpMethod, "POST")
            XCTAssertEqual(req.value(forHTTPHeaderField: "Content-Type"), "application/x-www-form-urlencoded")
            let body = String(data: URLProtocolStub.bodyOf(req) ?? Data(), encoding: .utf8) ?? ""
            XCTAssertTrue(body.contains("apikey=KEY"))
            XCTAssertTrue(body.contains("application=Claude%20Monitor"))
            XCTAssertTrue(body.contains("event=proj%3A%20Done"))
            XCTAssertTrue(body.contains("description=Finished%20responding."))
            XCTAssertTrue(body.contains("priority=0"))
            return .success((HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, Data()))
        }

        let result = await makeClient().send(apiKey: "KEY",
                                             event: "proj: Done",
                                             description: "Finished responding.")
        guard case .success = result else { return XCTFail("expected success, got \(result)") }
    }

    func test_send401MapsToInvalidAPIKey() async throws {
        URLProtocolStub.responder = { req in
            .success((HTTPURLResponse(url: req.url!, statusCode: 401, httpVersion: nil, headerFields: nil)!, Data()))
        }
        let result = await makeClient().send(apiKey: "X", event: "e", description: "d")
        guard case .failure(.invalidAPIKey) = result else { return XCTFail("got \(result)") }
    }

    func test_send406MapsToRateLimited() async throws {
        URLProtocolStub.responder = { req in
            .success((HTTPURLResponse(url: req.url!, statusCode: 406, httpVersion: nil, headerFields: nil)!, Data()))
        }
        let result = await makeClient().send(apiKey: "X", event: "e", description: "d")
        guard case .failure(.rateLimited) = result else { return XCTFail("got \(result)") }
    }

    func test_send500MapsToHttp() async throws {
        URLProtocolStub.responder = { req in
            .success((HTTPURLResponse(url: req.url!, statusCode: 500, httpVersion: nil, headerFields: nil)!,
                      "boom".data(using: .utf8)!))
        }
        let result = await makeClient().send(apiKey: "X", event: "e", description: "d")
        guard case .failure(.http(let code, let body)) = result else { return XCTFail("got \(result)") }
        XCTAssertEqual(code, 500)
        XCTAssertEqual(body, "boom")
    }

    func test_send400MapsToHttp() async throws {
        URLProtocolStub.responder = { req in
            .success((HTTPURLResponse(url: req.url!, statusCode: 400, httpVersion: nil, headerFields: nil)!,
                      "bad".data(using: .utf8)!))
        }
        let result = await makeClient().send(apiKey: "X", event: "e", description: "d")
        guard case .failure(.http(let code, let body)) = result else { return XCTFail("got \(result)") }
        XCTAssertEqual(code, 400)
        XCTAssertEqual(body, "bad")
    }

    func test_sendNetworkErrorMapsToNetworkCase() async throws {
        URLProtocolStub.responder = { _ in .failure(URLError(.notConnectedToInternet)) }
        let result = await makeClient().send(apiKey: "X", event: "e", description: "d")
        guard case .failure(.network(let urlErr)) = result else { return XCTFail("got \(result)") }
        XCTAssertEqual(urlErr.code, .notConnectedToInternet)
    }
}

private final class URLProtocolStub: URLProtocol {
    nonisolated(unsafe) static var responder: ((URLRequest) -> Result<(HTTPURLResponse, Data), URLError>)?

    static func reset() {
        responder = nil
    }

    static func bodyOf(_ req: URLRequest) -> Data? {
        if let stream = req.httpBodyStream {
            stream.open(); defer { stream.close() }
            var data = Data()
            let buf = UnsafeMutablePointer<UInt8>.allocate(capacity: 4096)
            defer { buf.deallocate() }
            while stream.hasBytesAvailable {
                let n = stream.read(buf, maxLength: 4096)
                if n <= 0 { break }
                data.append(buf, count: n)
            }
            return data
        }
        return req.httpBody
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let r = Self.responder else { fatalError("no responder set") }
        switch r(request) {
        case .success(let (resp, data)):
            client?.urlProtocol(self, didReceive: resp, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        case .failure(let urlError):
            client?.urlProtocol(self, didFailWithError: urlError)
        }
    }
    override func stopLoading() {}
}
