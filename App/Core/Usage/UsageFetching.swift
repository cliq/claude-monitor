import Foundation

/// Per-provider usage collection behind `UsagePoller`. Implementations own
/// networking/process details; the poller owns the timer, aggregation,
/// ordering, `updatedAt`, and snapshot publication.
protocol UsageFetching: Sendable {
    func fetch(account: UsageAccountConfig) async throws -> AccountUsage
}
