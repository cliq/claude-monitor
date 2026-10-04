// iOS/SessionsStore.swift
import Foundation

/// Polls the selected Mac's bridge for the dashboard's agent sessions. Session
/// states flip within seconds and the bridge only serializes in-memory state,
/// so this polls far more often than the usage snapshot.
@MainActor
final class SessionsStore: ObservableObject {
    static let refreshInterval: TimeInterval = 3

    @Published private(set) var snapshot: SessionsSnapshot?
    @Published private(set) var errorMessage: String?
    /// Phone clock minus Mac clock at the last fetch, so elapsed times count
    /// from the Mac's state changes even when the two clocks disagree.
    private(set) var clockOffset: TimeInterval = 0

    /// Mirrors `UsageStore.endpoint` — one Mac serves both tabs.
    var endpoint: BridgeEndpoint? {
        didSet {
            guard endpoint != oldValue else { return }
            snapshot = nil
            errorMessage = nil
            clockOffset = 0
            if loop != nil { startPolling() }
        }
    }

    private let fetcher: (BridgeEndpoint) async throws -> SessionsSnapshot
    private var loop: Task<Void, Never>?

    init(endpoint: BridgeEndpoint? = nil,
         fetcher: @escaping (BridgeEndpoint) async throws -> SessionsSnapshot = SessionsStore.fetch) {
        self.endpoint = endpoint
        self.fetcher = fetcher
    }

    func startPolling() {
        loop?.cancel()
        loop = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refresh()
                try? await Task.sleep(nanoseconds: UInt64(Self.refreshInterval * 1_000_000_000))
            }
        }
    }

    func stopPolling() {
        loop?.cancel()
        loop = nil
    }

    func refresh() async {
        guard let endpoint else { return }
        do {
            let snapshot = try await fetcher(endpoint)
            // The user may have switched Macs while this request was in flight.
            guard endpoint == self.endpoint else { return }
            if let generated = ISO8601DateFormatter().date(from: snapshot.generatedAt) {
                clockOffset = Date().timeIntervalSince(generated)
            }
            if snapshot != self.snapshot { self.snapshot = snapshot }
            errorMessage = nil
        } catch is CancellationError {
        } catch {
            guard endpoint == self.endpoint else { return }
            errorMessage = error.localizedDescription
        }
    }

    /// Seconds `session` has been in its current state at phone time `now`.
    func elapsed(_ session: RemoteSession, now: Date) -> TimeInterval {
        guard let entered = session.enteredStateDate else { return 0 }
        return now.timeIntervalSince(entered) - clockOffset
    }

    nonisolated static func fetch(from endpoint: BridgeEndpoint) async throws -> SessionsSnapshot {
        let response = try await BridgeClient.get("/sessions", from: endpoint.networkEndpoint)
        // Mac builds that predate the session feed only serve usage.
        if response.status == 404 { throw SessionsError.unsupportedMac }
        guard response.status == 200 else { throw BridgeError.http(response.status) }
        do {
            return try JSONDecoder().decode(SessionsSnapshot.self, from: response.body)
        } catch {
            throw BridgeError.badResponse
        }
    }
}

enum SessionsError: LocalizedError {
    case unsupportedMac

    var errorDescription: String? {
        "Update Claude Monitor on the Mac to see its sessions here"
    }
}
