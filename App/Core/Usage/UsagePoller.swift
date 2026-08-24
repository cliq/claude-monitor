import Foundation
import CoreGraphics

/// Polls usage for every discovered account — Claude Code via
/// `ClaudeUsageFetcher` (OAuth endpoint), Codex via `CodexUsageFetcher`
/// (local app-server) — and watches the Mac's display power state (mirrored
/// to the ESP32 panel backlight via `UsageBridgeServer`).
///
/// This class owns the timer, ordered aggregation, `updatedAt`, and the
/// single consistent snapshot publication; per-provider collection lives in
/// the `UsageFetching` implementations. Errors are isolated per account so
/// one failed Codex process never suppresses successful Claude results.
@MainActor
final class UsagePoller: ObservableObject {
    @Published var accounts: [AccountUsage] = []
    @Published var updatedAt: Date?
    @Published var displayOn: Bool = true

    /// Below this the Anthropic API 429s; the same cadence keeps Codex
    /// subprocess churn low.
    static let pollInterval: TimeInterval = 180

    private let accountsProvider: () -> [UsageAccountConfig]
    private let publish: (UsageSnapshot) -> Void
    private let fetchers: [AgentProvider: any UsageFetching]
    private var pollTimer: Timer?
    private var displayTimer: Timer?
    private var isPolling = false

    init(accountsProvider: @escaping () -> [UsageAccountConfig] = { UsageAccountConfig.discover() },
         publish: @escaping (UsageSnapshot) -> Void = { _ in },
         fetchers: [AgentProvider: any UsageFetching] = [
            .claude: ClaudeUsageFetcher(),
            .codex: CodexUsageFetcher(),
         ]) {
        self.accountsProvider = accountsProvider
        self.publish = publish
        self.fetchers = fetchers
    }

    func start() {
        guard pollTimer == nil else { return }
        Task { await self.pollAll() }
        pollTimer = Timer.scheduledTimer(withTimeInterval: Self.pollInterval, repeats: true) { [weak self] _ in
            Task { await self?.pollAll() }
        }
        displayTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            let asleep = CGDisplayIsAsleep(CGMainDisplayID()) != 0
            Task { @MainActor in self?.displayOn = !asleep }
        }
    }

    func stop() {
        pollTimer?.invalidate()
        pollTimer = nil
        displayTimer?.invalidate()
        displayTimer = nil
    }

    func snapshot() -> UsageSnapshot {
        let fmt = ISO8601DateFormatter()
        return UsageSnapshot(updatedAt: updatedAt.map { fmt.string(from: $0) }, accounts: accounts)
    }

    func pollAll() async {
        // No overlapping cycles: a slow Codex subprocess or network stall must
        // not pile up concurrent requests for the same account.
        guard !isPolling else { return }
        isPolling = true
        defer { isPolling = false }

        // Re-discover on every cycle so logins added/removed while the app is
        // running show up without a restart.
        let configs = accountsProvider()
        var results: [AccountUsage] = []
        for config in configs {
            guard let fetcher = fetchers[config.provider] else { continue }
            do {
                results.append(try await fetcher.fetch(account: config))
            } catch {
                var failed = AccountUsage(provider: config.provider, name: config.name, status: "error")
                failed.error = String(error.localizedDescription.prefix(200))
                results.append(failed)
            }
        }
        accounts = results
        updatedAt = Date()
        // @Published emits on willSet, so an external Combine sink observing
        // `accounts`/`updatedAt` individually could pair new accounts with the
        // old timestamp; publish only after both fields are consistent.
        publish(snapshot())
    }

    // Thin forwarders so existing call sites (and `Tests/UsagePollerTests.swift`)
    // keep compiling — the actual implementation lives in `UsageFormat` so it
    // can be shared without pulling in this poller's networking/keychain deps.
    nonisolated static func summarize(raw: [String: Any], name: String, plan: String) -> AccountUsage {
        UsageFormat.summarize(raw: raw, name: name, plan: plan)
    }

    /// Absolute local reset time: "23:50" if today, else "Fri 12:00".
    nonisolated static func formatReset(_ iso: String?) -> String {
        UsageFormat.formatReset(iso)
    }
}
