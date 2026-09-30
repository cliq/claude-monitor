// iOS/UsageStore.swift
import Foundation
import WidgetKit

/// Polls the selected Mac's bridge for the usage snapshot. The Mac polls
/// Anthropic/Codex every 180s; reading its cached snapshot over the LAN is
/// cheap, so the phone refreshes more often to pick up new polls promptly.
@MainActor
final class UsageStore: ObservableObject {
    static let refreshInterval: TimeInterval = 30

    @Published private(set) var snapshot: UsageSnapshot?
    @Published private(set) var errorMessage: String?
    @Published var endpoint: BridgeEndpoint? {
        didSet {
            guard endpoint != oldValue else { return }
            BridgeEndpointStore.save(endpoint, to: defaults)
            // Account ids from another Mac mean nothing here.
            widgetAccountID = nil
            snapshot = nil
            errorMessage = nil
            reloadWidget()
            Task { await refresh() }
        }
    }

    /// The account the Home Screen widget shows (`AccountUsage.id`); nil
    /// keeps the Mac's "Widget · ESP32" selection.
    @Published var widgetAccountID: String? {
        didSet {
            guard widgetAccountID != oldValue else { return }
            WidgetAccountStore.save(widgetAccountID, to: defaults)
            reloadWidget()
        }
    }

    private let defaults: UserDefaults
    private let reloadWidgets: () -> Void
    private var loop: Task<Void, Never>?

    init(defaults: UserDefaults = BridgeEndpointStore.sharedDefaults,
         reloadWidgets: @escaping () -> Void = {
             WidgetCenter.shared.reloadTimelines(ofKind: UsageSnapshotStore.widgetKind)
         }) {
        self.defaults = defaults
        self.reloadWidgets = reloadWidgets
        // First builds saved the choice in standard defaults; carry it over
        // so the widget can see it.
        if BridgeEndpointStore.load(from: defaults) == nil,
           defaults != .standard,
           let legacy = BridgeEndpointStore.load(from: .standard) {
            BridgeEndpointStore.save(legacy, to: defaults)
        }
        self.endpoint = BridgeEndpointStore.load(from: defaults)
        self.widgetAccountID = WidgetAccountStore.load(from: defaults)
    }

    /// When the Mac last polled usage (not when the phone last fetched).
    var updatedAt: Date? {
        guard let iso = snapshot?.updatedAt else { return nil }
        return ISO8601DateFormatter().date(from: iso)
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
            let snapshot = try await Self.fetch(from: endpoint)
            // The user may have switched Macs while this request was in flight.
            guard endpoint == self.endpoint else { return }
            // The widget fetches for itself; nudge it only when the Mac has
            // polled again, not on every 30s refresh.
            if snapshot.updatedAt != self.snapshot?.updatedAt { reloadWidget() }
            self.snapshot = snapshot
            errorMessage = nil
        } catch is CancellationError {
        } catch {
            guard endpoint == self.endpoint else { return }
            errorMessage = error.localizedDescription
        }
    }

    private func reloadWidget() { reloadWidgets() }

    /// `/panel` has every polled account; Mac builds that predate it only
    /// serve `/usage` (the widget/ESP32 selection), so fall back on 404.
    nonisolated static func fetch(from endpoint: BridgeEndpoint) async throws -> UsageSnapshot {
        var response = try await BridgeClient.get("/panel", from: endpoint.networkEndpoint)
        if response.status == 404 {
            response = try await BridgeClient.get("/usage", from: endpoint.networkEndpoint)
        }
        guard response.status == 200 else { throw BridgeError.http(response.status) }
        do {
            return try JSONDecoder().decode(UsageSnapshot.self, from: response.body)
        } catch {
            throw BridgeError.badResponse
        }
    }
}
