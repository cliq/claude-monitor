import XCTest
@testable import ClaudeMonitor

/// Counts fetches and answers with a fixed "ok" result named after the config,
/// so tests can tell a real poll from a cache-only republish.
private final class CountingFetcher: UsageFetching, @unchecked Sendable {
    private let lock = NSLock()
    private var _fetchCount = 0
    var fetchCount: Int { lock.withLock { _fetchCount } }

    func fetch(account: UsageAccountConfig) async throws -> AccountUsage {
        lock.withLock { _fetchCount += 1 }
        return AccountUsage(provider: account.provider, name: account.name, status: "ok",
                            sessionPct: 40, weeklyPct: 20)
    }
}

final class UsagePollerTests: XCTestCase {
    // MARK: - external snapshot / republish

    private let personal = UsageAccountConfig(name: "personal", configDir: "/h/.claudewho-personal")
    private let work = UsageAccountConfig(name: "work", configDir: "/h/.claudewho-work",
                                          showOnExternalDisplays: false)

    @MainActor
    func test_pollAll_publishesOnlyExternalAccounts_panelKeepsAll() async {
        let fetcher = CountingFetcher()
        var published: [UsageSnapshot] = []
        let poller = UsagePoller(accountsProvider: { [self.personal, self.work] },
                                 publish: { published.append($0) },
                                 fetchers: [.claude: fetcher])

        await poller.pollAll()

        XCTAssertEqual(fetcher.fetchCount, 2)
        XCTAssertEqual(poller.accounts.map(\.name), ["personal", "work"])
        XCTAssertEqual(poller.snapshot().accounts.map(\.name), ["personal", "work"])
        XCTAssertEqual(poller.externalSnapshot().accounts.map(\.name), ["personal"])
        XCTAssertEqual(published.count, 1)
        XCTAssertEqual(published.first?.accounts.map(\.name), ["personal"])
        XCTAssertNotNil(published.first?.updatedAt)
    }

    @MainActor
    func test_republish_reappliesFlagsAndNamesWithoutFetching() async {
        let fetcher = CountingFetcher()
        var configs = [personal, work]
        var published: [UsageSnapshot] = []
        let poller = UsagePoller(accountsProvider: { configs },
                                 publish: { published.append($0) },
                                 fetchers: [.claude: fetcher])
        await poller.pollAll()
        let updatedAt = poller.updatedAt

        // User flips work on, personal off, and renames personal — all cache-only.
        configs = [
            UsageAccountConfig(name: "home", configDir: "/h/.claudewho-personal", showOnExternalDisplays: false),
            UsageAccountConfig(name: "work", configDir: "/h/.claudewho-work"),
        ]
        poller.republish()

        XCTAssertEqual(fetcher.fetchCount, 2, "republish must not hit the fetchers")
        XCTAssertEqual(poller.accounts.map(\.name), ["home", "work"])
        XCTAssertEqual(poller.externalSnapshot().accounts.map(\.name), ["work"])
        XCTAssertEqual(published.last?.accounts.map(\.name), ["work"])
        XCTAssertEqual(poller.updatedAt, updatedAt, "cached numbers are no fresher")
    }

    @MainActor
    func test_republish_skipsAccountsNeverPolled() async {
        let fetcher = CountingFetcher()
        var configs = [personal]
        let poller = UsagePoller(accountsProvider: { configs },
                                 fetchers: [.claude: fetcher])
        await poller.pollAll()

        configs = [personal, work]
        poller.republish()

        XCTAssertEqual(poller.accounts.map(\.name), ["personal"])
        XCTAssertEqual(fetcher.fetchCount, 1)
    }

    // MARK: - summarize

    private func isoString(hoursFromNow hours: Double) -> String {
        ISO8601DateFormatter().string(from: Date().addingTimeInterval(hours * 3600))
    }

    func test_summarize_readsSessionWeeklyAndModelLimits() {
        let raw: [String: Any] = [
            "five_hour": ["utilization": 42.6, "resets_at": isoString(hoursFromNow: 1)],
            "seven_day": ["utilization": 11.4, "resets_at": isoString(hoursFromNow: 1)],
            "limits": [
                ["kind": "weekly", "percent": 99],
                ["kind": "weekly_scoped",
                 "percent": 7,
                 "resets_at": isoString(hoursFromNow: 2),
                 "scope": ["model": ["display_name": "Fable"]]],
            ],
        ]

        let out = UsagePoller.summarize(raw: raw, name: "personal", plan: "max")
        XCTAssertEqual(out.status, "ok")
        XCTAssertEqual(out.plan, "MAX")
        XCTAssertEqual(out.sessionPct, 43)
        XCTAssertFalse(out.sessionResets.isEmpty)
        XCTAssertEqual(out.weeklyPct, 11)
        XCTAssertEqual(out.modelPct, 7)
        XCTAssertEqual(out.modelLabel, "FABLE")
        XCTAssertFalse(out.modelResets.isEmpty)
    }

    func test_summarize_missingSessionMeansIdle() {
        let out = UsagePoller.summarize(raw: [:], name: "x", plan: "")
        XCTAssertEqual(out.sessionPct, -1)
        XCTAssertEqual(out.sessionResets, "")
        XCTAssertEqual(out.modelPct, -1)
    }

    func test_summarize_ignoresUnscopedLimits() {
        let raw: [String: Any] = [
            "limits": [["kind": "weekly", "percent": 50]],
        ]
        let out = UsagePoller.summarize(raw: raw, name: "x", plan: "")
        XCTAssertEqual(out.modelPct, -1)
        XCTAssertEqual(out.modelLabel, "")
    }

    func test_summarize_populatesRawResetsAtVerbatimAlongsideFormatted() {
        let sessionResetsAt = isoString(hoursFromNow: 1)
        let weeklyResetsAt = isoString(hoursFromNow: 2)
        let modelResetsAt = isoString(hoursFromNow: 3)
        let raw: [String: Any] = [
            "five_hour": ["utilization": 42.6, "resets_at": sessionResetsAt],
            "seven_day": ["utilization": 11.4, "resets_at": weeklyResetsAt],
            "limits": [
                ["kind": "weekly_scoped",
                 "percent": 7,
                 "resets_at": modelResetsAt,
                 "scope": ["model": ["display_name": "Fable"]]],
            ],
        ]

        let out = UsagePoller.summarize(raw: raw, name: "personal", plan: "max")
        XCTAssertEqual(out.sessionResetsAt, sessionResetsAt)
        XCTAssertEqual(out.weeklyResetsAt, weeklyResetsAt)
        XCTAssertEqual(out.modelResetsAt, modelResetsAt)
        XCTAssertFalse(out.sessionResets.isEmpty)
        XCTAssertFalse(out.weeklyResets.isEmpty)
        XCTAssertFalse(out.modelResets.isEmpty)
    }

    // MARK: - formatReset

    // Fixed calendar day so "today"/"same day" assertions never depend on
    // wall-clock time — both `now` and the reset are built from the same
    // DateComponents.
    private func fixedDate(hour: Int, minute: Int, second: Int = 0, dayOffset: Int = 0) -> Date {
        var components = DateComponents()
        components.year = 2026
        components.month = 7
        components.day = 19 + dayOffset
        components.hour = hour
        components.minute = minute
        components.second = second
        return Calendar.current.date(from: components)!
    }

    func test_formatReset_nilAndGarbageAreEmpty() {
        XCTAssertEqual(UsagePoller.formatReset(nil), "")
        XCTAssertEqual(UsagePoller.formatReset("not a date"), "")
    }

    func test_formatReset_todayUsesTimeOnly() {
        // now is before the reset, both on the same fixed calendar day.
        let now = fixedDate(hour: 9, minute: 0)
        let reset = fixedDate(hour: 12, minute: 30)
        let fmt = ISO8601DateFormatter()
        let out = UsageFormat.formatReset(fmt.string(from: reset), now: now)
        XCTAssertEqual(out, "12:30")
    }

    func test_formatReset_otherDayIncludesWeekday() {
        // Deterministic regardless of wall clock — a far-future ISO date.
        let future = Calendar.current.date(byAdding: .year, value: 5, to: Date())!
        let fmt = ISO8601DateFormatter()
        let out = UsagePoller.formatReset(fmt.string(from: future))
        // "E HH:mm" — three-letter weekday, space, time.
        XCTAssertTrue(out.range(of: #"^[A-Z][a-z]{2} \d{2}:\d{2}$"#, options: .regularExpression) != nil,
                      "expected 'E HH:mm' format, got '\(out)'")
    }

    func test_formatReset_acceptsFractionalSeconds() {
        let now = fixedDate(hour: 9, minute: 0)
        let noon = fixedDate(hour: 12, minute: 0)
        let fmt = ISO8601DateFormatter()
        fmt.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        XCTAssertEqual(UsageFormat.formatReset(fmt.string(from: noon), now: now), "12:00")
    }
}
