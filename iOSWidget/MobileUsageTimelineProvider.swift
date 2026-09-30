// iOSWidget/MobileUsageTimelineProvider.swift
import Foundation
import WidgetKit

/// Unlike the Mac widget (which only reads the file the app writes after each
/// poll), the iOS app runs only in the foreground, so the widget fetches from
/// the Mac's bridge itself on every timeline reload. It reads `/usage` — the
/// accounts checked under "Widget · ESP32" on the Mac — unless an account was
/// picked in the app (`WidgetAccountStore`), in which case it reads `/panel`
/// and shows only that one. The last good (unfiltered) snapshot is cached in
/// the App Group so it can show "as of" away from home.
struct MobileUsageTimelineProvider: TimelineProvider {
    /// WidgetKit budgets reloads (roughly every 15–30 min in practice); ask
    /// for the minimum and let the app's reloads fill the gaps.
    static let refreshInterval: TimeInterval = 15 * 60

    func placeholder(in context: Context) -> UsageEntry {
        UsageEntry(date: .now, snapshot: .placeholderSample)
    }

    func getSnapshot(in context: Context, completion: @escaping (UsageEntry) -> Void) {
        if context.isPreview {
            completion(UsageEntry(date: .now, snapshot: .placeholderSample))
            return
        }
        Task { completion(UsageEntry(date: .now, snapshot: await Self.loadSnapshot())) }
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<UsageEntry>) -> Void) {
        Task {
            let snapshot = await Self.loadSnapshot()
            let now = Date()
            // Later entries re-render reset labels and staleness without a fetch.
            let entries = [now, now + 600, now + 1800, now + 3600].map {
                UsageEntry(date: $0, snapshot: snapshot)
            }
            completion(Timeline(entries: entries, policy: .after(now + Self.refreshInterval)))
        }
    }

    /// Live snapshot from the selected Mac, else the last cached one, narrowed
    /// to the account picked in the app. Nil when no Mac is selected (the
    /// widget shows its empty state).
    static func loadSnapshot() async -> UsageSnapshot? {
        guard let endpoint = BridgeEndpointStore.load() else { return nil }
        let accountID = WidgetAccountStore.load()
        let snapshot: UsageSnapshot?
        do {
            var response = try await BridgeClient.get(WidgetAccountStore.path(for: accountID),
                                                      from: endpoint.networkEndpoint, timeout: 5)
            // Mac builds that predate `/panel` only serve `/usage`.
            if response.status == 404, accountID != nil {
                response = try await BridgeClient.get("/usage", from: endpoint.networkEndpoint, timeout: 5)
            }
            guard response.status == 200 else { throw BridgeError.http(response.status) }
            let fetched = try JSONDecoder().decode(UsageSnapshot.self, from: response.body)
            UsageSnapshotStore.write(fetched)
            snapshot = fetched
        } catch {
            snapshot = UsageSnapshotStore.read()
        }
        // Filter after the cache so a pick made away from the Mac still applies.
        return snapshot.map { WidgetAccountStore.filter($0, to: accountID) }
    }
}
