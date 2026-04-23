import Foundation
import Network

/// Minimal single-endpoint HTTP server for receiving hook events on localhost.
/// Accepts `POST /event` with a JSON `HookEvent` body.
final class EventServer {
    private let onEvent: (HookEvent) -> Void
    private var listener: NWListener?
    private let queue = DispatchQueue(label: "com.cliqconsulting.claudemonitor.eventserver")

    /// Live port after `start()`. Nil before or on failure.
    private(set) var port: UInt16?

    init(onEvent: @escaping (HookEvent) -> Void) {
        self.onEvent = onEvent
    }

    func start() throws {
        let params = NWParameters.tcp
        let listener = try NWListener(using: params, on: .any)
        self.listener = listener

        listener.newConnectionHandler = { [weak self] connection in
            self?.handle(connection: connection)
        }

        let started = DispatchSemaphore(value: 0)
        listener.stateUpdateHandler = { [weak self] state in
            if case .ready = state {
                self?.port = listener.port?.rawValue
                started.signal()
            } else if case .failed = state {
                started.signal()
            }
        }
        listener.start(queue: queue)
        _ = started.wait(timeout: .now() + 2)

        guard port != nil else {
            throw NSError(domain: "EventServer", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "listener failed to bind"])
        }
    }

    func stop() {
        listener?.cancel()
        listener = nil
        port = nil
    }

    private func handle(connection: NWConnection) {
        connection.start(queue: queue)
        readRequest(on: connection, accumulated: Data())
    }

    private func readRequest(on connection: NWConnection, accumulated: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            var buffer = accumulated
            if let data = data { buffer.append(data) }

            if let parsed = RawHTTPRequest.parse(buffer) {
                self.respond(to: parsed, on: connection)
                return
            }
            if isComplete || error != nil {
                connection.cancel()
                return
            }
            self.readRequest(on: connection, accumulated: buffer)
        }
    }

    private func respond(to req: RawHTTPRequest, on connection: NWConnection) {
        defer { connection.send(content: nil, isComplete: true, completion: .contentProcessed { _ in
            connection.cancel()
        }) }

        guard req.method == "POST", req.path == "/event" else {
            send(status: 405, message: "Method Not Allowed", connection: connection)
            return
        }
        guard let body = req.body else {
            send(status: 400, message: "Bad Request", connection: connection)
            return
        }
        do {
            let event = try JSONDecoder().decode(HookEvent.self, from: body)
            onEvent(event)
            send(status: 204, message: "No Content", connection: connection)
        } catch {
            send(status: 400, message: "Bad Request", connection: connection)
        }
    }

    private func send(status: Int, message: String, connection: NWConnection) {
        let line = "HTTP/1.1 \(status) \(message)\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
        connection.send(content: line.data(using: .utf8), completion: .contentProcessed { _ in })
    }
}

/// Tiny HTTP/1.1 request parser — just enough for our single endpoint.
struct RawHTTPRequest {
    let method: String
    let path: String
    let headers: [String: String]
    let body: Data?

    static func parse(_ data: Data) -> RawHTTPRequest? {
        guard let headerEnd = data.range(of: Data("\r\n\r\n".utf8)) else { return nil }
        let headerData = data.subdata(in: 0..<headerEnd.lowerBound)
        guard let headerStr = String(data: headerData, encoding: .utf8) else { return nil }

        let lines = headerStr.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else { return nil }
        let parts = requestLine.split(separator: " ").map(String.init)
        guard parts.count >= 2 else { return nil }

        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            if let colon = line.firstIndex(of: ":") {
                let key = line[..<colon].lowercased()
                let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
                headers[key] = value
            }
        }

        let bodyStart = headerEnd.upperBound
        let contentLength = Int(headers["content-length"] ?? "0") ?? 0
        let available = data.count - bodyStart
        if contentLength > 0 && available < contentLength { return nil } // body incomplete

        let body = contentLength > 0
            ? data.subdata(in: bodyStart..<(bodyStart + contentLength))
            : nil

        return RawHTTPRequest(method: parts[0], path: parts[1], headers: headers, body: body)
    }
}
