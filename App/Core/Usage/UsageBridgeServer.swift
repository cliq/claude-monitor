import Foundation
import Network

/// Minimal HTTP server serving the ESP32 desk display and the iOS app over the LAN:
///   GET /usage   -> usage snapshot JSON (schema the firmware expects), only
///                   the accounts checked for external displays
///   GET /panel   -> same schema with every polled account — the full usage
///                   panel, as the iOS app renders it
///   GET /display -> "on" | "off" (Mac display power state, plain text)
///
/// Unlike `EventServer` (loopback, ephemeral port published via the port file),
/// this listens on all interfaces at a fixed user-configured port — the ESP32
/// polls it over WiFi. Pass port 0 to bind an ephemeral port (tests).
final class UsageBridgeServer {
    static let defaultPort: UInt16 = 8737
    /// Bonjour service type the iOS app browses for. Must match
    /// `NSBonjourServices` in the iOS target's Info.plist.
    static let bonjourServiceType = "_claudemonitor._tcp"

    private var listener: NWListener?
    private let queue = DispatchQueue(label: "com.cliqconsulting.claudemonitor.usagebridge")
    private let snapshotProvider: @MainActor () -> UsageSnapshot
    private let panelProvider: @MainActor () -> UsageSnapshot
    private let displayProvider: @MainActor () -> Bool

    /// Live port after `start()`. Nil before or on failure.
    private(set) var port: UInt16?

    /// `panel` defaults to `snapshot` when the caller has no wider view.
    init(snapshot: @escaping @MainActor () -> UsageSnapshot,
         panel: (@MainActor () -> UsageSnapshot)? = nil,
         display: @escaping @MainActor () -> Bool) {
        self.snapshotProvider = snapshot
        self.panelProvider = panel ?? snapshot
        self.displayProvider = display
    }

    /// `advertise` publishes the listener over Bonjour (named after this Mac)
    /// so the iOS app can find it without typing an address. Off for tests.
    func start(port requestedPort: UInt16 = UsageBridgeServer.defaultPort, advertise: Bool = false) throws {
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        let nwPort: NWEndpoint.Port = requestedPort == 0 ? .any : NWEndpoint.Port(rawValue: requestedPort)!
        let listener = try NWListener(using: params, on: nwPort)
        if advertise {
            listener.service = NWListener.Service(type: Self.bonjourServiceType)
        }
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
            self.listener = nil
            throw NSError(domain: "UsageBridgeServer", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "listener failed to bind port \(requestedPort)"])
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
        connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            var buffer = accumulated
            if let data { buffer.append(data) }

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
        let path = req.path.hasSuffix("/") && req.path.count > 1 ? String(req.path.dropLast()) : req.path
        Task { @MainActor in
            let (status, body, ctype): (String, Data, String)
            switch path {
            case "/usage":
                let json = (try? JSONEncoder().encode(self.snapshotProvider())) ?? Data("{}".utf8)
                (status, body, ctype) = ("200 OK", json, "application/json")
            case "/panel":
                let json = (try? JSONEncoder().encode(self.panelProvider())) ?? Data("{}".utf8)
                (status, body, ctype) = ("200 OK", json, "application/json")
            case "/display":
                let on = self.displayProvider()
                (status, body, ctype) = ("200 OK", Data((on ? "on" : "off").utf8), "text/plain")
            default:
                (status, body, ctype) = ("404 Not Found", Data("not found".utf8), "text/plain")
            }
            var response = Data("HTTP/1.1 \(status)\r\nContent-Type: \(ctype)\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n".utf8)
            response.append(body)
            connection.send(content: response, completion: .contentProcessed { _ in
                connection.cancel()
            })
        }
    }
}
