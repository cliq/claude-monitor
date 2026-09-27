// iOS/BridgeClient.swift
import Foundation
import Network

/// The status and body of one reply from the Mac's `UsageBridgeServer`.
struct BridgeHTTPResponse: Equatable {
    let status: Int
    let body: Data

    /// Parses a complete HTTP/1.1 response (the bridge always closes the
    /// connection after replying). Nil until the headers have arrived, or
    /// when the body is shorter than its Content-Length.
    static func parse(_ data: Data) -> BridgeHTTPResponse? {
        guard let headerEnd = data.range(of: Data("\r\n\r\n".utf8)),
              let header = String(data: data[..<headerEnd.lowerBound], encoding: .utf8) else { return nil }
        let lines = header.components(separatedBy: "\r\n")
        let statusParts = lines.first?.split(separator: " ") ?? []
        guard statusParts.count >= 2, statusParts[0].hasPrefix("HTTP/"),
              let status = Int(statusParts[1]) else { return nil }

        var body = Data(data[headerEnd.upperBound...])
        let contentLength = lines.dropFirst().lazy.compactMap { line -> Int? in
            guard let colon = line.firstIndex(of: ":"),
                  line[..<colon].lowercased() == "content-length" else { return nil }
            return Int(line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces))
        }.first
        if let contentLength {
            guard body.count >= contentLength else { return nil }
            body = body.prefix(contentLength)
        }
        return BridgeHTTPResponse(status: status, body: body)
    }
}

enum BridgeError: LocalizedError {
    case timeout
    case badResponse
    case http(Int)
    case unreachable(String)

    var errorDescription: String? {
        switch self {
        case .timeout: return "The Mac didn't answer in time"
        case .badResponse: return "The Mac sent a reply this app can't read"
        case .http(let status): return "The Mac answered with HTTP \(status)"
        case .unreachable(let reason): return reason
        }
    }
}

/// Plain-HTTP GET over `NWConnection` rather than `URLSession`, so a Bonjour
/// service endpoint can be used directly (no resolve step) and ATS never
/// applies to the LAN connection.
enum BridgeClient {
    static func get(_ path: String, from endpoint: NWEndpoint,
                    timeout: TimeInterval = 6) async throws -> BridgeHTTPResponse {
        try await BridgeRequest(endpoint: endpoint, path: path).run(timeout: timeout)
    }
}

/// One request/response exchange. All mutable state lives on `queue`.
private final class BridgeRequest: @unchecked Sendable {
    private let connection: NWConnection
    private let path: String
    private let queue = DispatchQueue(label: "com.cliqconsulting.claudemonitor.ios.bridge")
    private var buffer = Data()
    private var continuation: CheckedContinuation<BridgeHTTPResponse, Error>?
    private var finished = false

    init(endpoint: NWEndpoint, path: String) {
        self.connection = NWConnection(to: endpoint, using: .tcp)
        self.path = path
    }

    func run(timeout: TimeInterval) async throws -> BridgeHTTPResponse {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                queue.async { self.start(continuation, timeout: timeout) }
            }
        } onCancel: {
            queue.async { self.finish(.failure(CancellationError())) }
        }
    }

    private func start(_ continuation: CheckedContinuation<BridgeHTTPResponse, Error>, timeout: TimeInterval) {
        guard !finished else {
            continuation.resume(throwing: CancellationError())
            return
        }
        self.continuation = continuation
        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                self.send()
            case .waiting(let error), .failed(let error):
                // `.waiting` would retry forever: no route, connection refused
                // (bridge off) or local-network access denied. Fail fast.
                self.finish(.failure(BridgeError.unreachable(Self.describe(error))))
            default:
                break
            }
        }
        connection.start(queue: queue)
        queue.asyncAfter(deadline: .now() + timeout) { [weak self] in
            self?.finish(.failure(BridgeError.timeout))
        }
    }

    private func send() {
        let request = "GET \(path) HTTP/1.1\r\nHost: claude-monitor\r\nAccept: application/json\r\nConnection: close\r\n\r\n"
        connection.send(content: Data(request.utf8), completion: .contentProcessed { [weak self] error in
            if let error {
                self?.finish(.failure(BridgeError.unreachable(Self.describe(error))))
            } else {
                self?.receive()
            }
        })
    }

    private func receive() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let data { self.buffer.append(data) }
            if isComplete || error != nil {
                if let response = BridgeHTTPResponse.parse(self.buffer) {
                    self.finish(.success(response))
                } else if let error {
                    self.finish(.failure(BridgeError.unreachable(Self.describe(error))))
                } else {
                    self.finish(.failure(BridgeError.badResponse))
                }
            } else {
                self.receive()
            }
        }
    }

    private func finish(_ result: Result<BridgeHTTPResponse, Error>) {
        guard !finished else { return }
        finished = true
        connection.stateUpdateHandler = nil
        connection.cancel()
        continuation?.resume(with: result)
        continuation = nil
    }

    private static func describe(_ error: NWError) -> String {
        switch error {
        case .posix(.ECONNREFUSED):
            return "Connection refused — is \"Serve usage to external displays\" on in the Mac's Settings → Usage?"
        case .dns(let code) where code == -65570: // kDNSServiceErr_PolicyDenied
            return "Local network access is off — allow it in iOS Settings → Claude Monitor"
        default:
            return error.localizedDescription
        }
    }
}
