import Foundation

/// Per-provider usage collection behind `UsagePoller`. Implementations own
/// networking/process details; the poller owns the timer, aggregation,
/// ordering, `updatedAt`, and snapshot publication.
protocol UsageFetching: Sendable {
    func fetch(account: UsageAccountConfig) async throws -> AccountUsage
}

/// Shared request details for fetchers that call a provider's HTTP API as
/// the monitor itself (Claude's endpoint needs its own `claude-code/…` agent).
enum UsageHTTP {
    static var userAgent: String {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev"
        return "ClaudeMonitor/\(version)"
    }
}

/// Best-effort, time-boxed cache for secondary lookups (plan names,
/// subscriptions, reset grants) that change far less often than usage. A
/// failed load returns the last good value, or nil — never an error, so a
/// side lookup can't turn an account row red.
actor UsageSideInfoCache<Value: Sendable> {
    private var entries: [String: (value: Value, fetchedAt: Date)] = [:]

    func value(for key: String, ttl: TimeInterval, now: Date = Date(),
               load: @Sendable () async throws -> Value) async -> Value? {
        if let entry = entries[key], now.timeIntervalSince(entry.fetchedAt) < ttl {
            return entry.value
        }
        do {
            let value = try await load()
            entries[key] = (value, now)
            return value
        } catch {
            return entries[key]?.value
        }
    }
}
