import XCTest
@testable import ClaudeMonitor

final class ZCodeUsageTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_790_900_000)

    /// "zai-test-key.abc123" encrypted the way ZCode does, with
    /// `ZCODE_CREDENTIAL_SECRET=test-secret` (generated once with Node's crypto).
    private let encrypted = "enc:v1:BwcHBwcHBwcHBwcH.2kIG7s-e_GfN8c4zAd5lZg.zy-10kQsPJVugWN-yqCKYxoRrw"
    private let testKey = ZCodeCredentialStore.key(secret: "test-secret")
    private let individualKeyName =
        "account-provider:coding-plan:account:zai-individual-coding-plan:account:8da0bb0f-1267-4522-b73a-f33a32e9a22e:api-key"

    // MARK: - Credential store

    func test_defaultSecret_matchesZCodeFallback() {
        XCTAssertEqual(ZCodeCredentialStore.defaultSecret(home: "/Users/me", username: "me"),
                       "zcode-credential-fallback:darwin:/Users/me:me")
    }

    func test_decrypt_roundTripsNodeCiphertext() throws {
        XCTAssertEqual(try ZCodeCredentialStore.decrypt(encrypted, key: testKey), "zai-test-key.abc123")
    }

    func test_decrypt_wrongKeyThrowsActionableError() {
        XCTAssertThrowsError(try ZCodeCredentialStore.decrypt(encrypted, key: ZCodeCredentialStore.key(secret: "nope"))) {
            XCTAssertTrue($0.localizedDescription.contains("ZCODE_CREDENTIAL_SECRET"))
        }
        XCTAssertThrowsError(try ZCodeCredentialStore.decrypt("enc:v1:abc", key: testKey))
    }

    func test_decrypt_passesPlaintextThrough() throws {
        XCTAssertEqual(try ZCodeCredentialStore.decrypt("plain", key: testKey), "plain")
    }

    func test_codingPlanAPIKey_picksIndividualZaiPlan() throws {
        let credentials = [
            "oauth:zai:access_token": "enc:v1:ignored",
            "account-provider:coding-plan:account:zai-team-coding-plan:account:x:api-key": "enc:v1:ignored",
            individualKeyName: encrypted,
        ]
        XCTAssertEqual(try ZCodeCredentialStore.codingPlanAPIKey(credentials: credentials, key: testKey),
                       "zai-test-key.abc123")
    }

    func test_codingPlanAPIKey_reportsMissingOrUnsupportedPlans() {
        XCTAssertThrowsError(try ZCodeCredentialStore.codingPlanAPIKey(credentials: [:], key: testKey)) {
            XCTAssertTrue($0.localizedDescription.contains("no Coding Plan"))
        }
        let team = ["account-provider:coding-plan:account:zai-team-coding-plan:account:x:api-key": encrypted]
        XCTAssertThrowsError(try ZCodeCredentialStore.codingPlanAPIKey(credentials: team, key: testKey)) {
            XCTAssertTrue($0.localizedDescription.contains("not") || $0.localizedDescription.contains("only"))
        }
    }

    // MARK: - Mapping

    private func decode(_ json: String) throws -> ZaiQuotaEnvelope {
        try JSONDecoder().decode(ZaiQuotaEnvelope.self, from: Data(json.utf8))
    }

    /// Shape observed from the live endpoint for a Pro plan.
    private let liveResponse = """
    {"code":200,"msg":"Operation successful","data":{"limits":[
      {"type":"CREDIT_LIMIT","unit":3,"number":5,"usage":12000,"currentValue":1450,"remaining":10549,"percentage":12,"nextResetTime":1790957911471},
      {"type":"CREDIT_LIMIT","unit":6,"number":1,"usage":60000,"currentValue":1450,"remaining":58549,"percentage":2,"nextResetTime":1791542496984}
    ],"level":"pro"},"success":true}
    """

    func test_summarize_liveShape() throws {
        let usage = try ZaiUsageMapper.summarize(try decode(liveResponse), name: "zcode", now: now)
        XCTAssertEqual(usage.provider, .zcode)
        XCTAssertEqual(usage.plan, "PRO")
        XCTAssertEqual(usage.metrics.map(\.label), ["SESSION", "WEEKLY"])
        XCTAssertEqual(usage.metrics.map(\.usedPct), [12, 2])
        XCTAssertNil(usage.metrics[0].detail, "credit amounts carry no unit word")
        XCTAssertEqual(usage.sessionPct, 12)
        XCTAssertEqual(usage.sessionResetsAt, "2026-10-02T16:18:31Z")
        XCTAssertEqual(usage.weeklyPct, 2)
        XCTAssertEqual(usage.weeklyResetsAt, "2026-10-09T10:41:36Z")
        XCTAssertEqual(usage.modelPct, -1, "no extra window → model slot idle")
    }

    func test_summarize_toolCallsAndOtherWindows() throws {
        let json = """
        {"code":0,"data":{"limits":[
          {"type":"TIME_LIMIT","unit":5,"number":1,"usage":1000,"currentValue":250,"remaining":750,"nextResetTime":1793000000000},
          {"type":"TOKENS_LIMIT","unit":5,"number":1,"percentage":40},
          {"type":"TOKENS_LIMIT","unit":3,"number":5,"percentage":99.6},
          {"type":"TOKENS_LIMIT","unit":9,"number":2,"percentage":1}
        ]}}
        """
        let usage = try ZaiUsageMapper.summarize(try decode(json), name: "zcode", now: now)
        XCTAssertEqual(usage.metrics.map(\.label), ["SESSION", "MONTH", "LIMIT", "TOOLS"])
        XCTAssertEqual(usage.metrics.map(\.usedPct), [100, 40, 1, 25], "TIME_LIMIT % falls back to used/total")
        XCTAssertEqual(usage.metrics[3].detail, "250 / 1000 tool calls")
        XCTAssertEqual(usage.plan, "")
        XCTAssertEqual(usage.modelLabel, "MONTH", "first non-session/weekly window feeds the model slot")
    }

    func test_summarize_failedEnvelopeThrowsServerMessage() {
        XCTAssertThrowsError(try ZaiUsageMapper.summarize(
            try decode(#"{"code":1001,"msg":"Invalid API key","success":false}"#), name: "zcode", now: now)) {
            XCTAssertEqual($0.localizedDescription, "Z.ai: Invalid API key")
        }
        XCTAssertThrowsError(try ZaiUsageMapper.summarize(try decode(#"{"code":200}"#), name: "zcode", now: now))
    }

    func test_windowLabel_isNeutral() {
        XCTAssertEqual(ZaiUsageMapper.windowLabel(unit: 3, number: 8), "8H")
        XCTAssertEqual(ZaiUsageMapper.windowLabel(unit: 6, number: 2), "2W")
        XCTAssertEqual(ZaiUsageMapper.windowLabel(unit: 5, number: 3), "3MO")
        XCTAssertEqual(ZaiUsageMapper.windowLabel(unit: nil, number: nil), "LIMIT")
    }

    // MARK: - Subscription and resets

    /// Live `subscription/list` entry, trimmed to non-sensitive fields.
    private let subscriptionList = """
    {"code":200,"msg":"Operation successful","data":[
      {"productId":"product-448ee2","productName":"GLM Coding Pro","status":"VALID",
       "valid":"2026-10-02 18:41:37-2026-11-02 18:41:37","autoRenew":1,"nextRenewTime":"2026-11-02",
       "billingCycle":"monthly","inCurrentPeriod":true,"actualPrice":80.00}],"success":true}
    """

    func test_currentPlan_autoRenewingSubscription() throws {
        let list = try XCTUnwrap(try JSONDecoder().decode(ZaiEnvelope<[ZaiSubscription]>.self,
                                                          from: Data(subscriptionList.utf8)).payload)
        XCTAssertEqual(ZaiSubscription.currentPlan(in: list),
                       ZaiPlanInfo(productName: "GLM Coding Pro", renews: true, date: "2026-11-02"))
    }

    func test_currentPlan_nonRenewingFallsBackToValidRange_andSkipsInactive() throws {
        let json = """
        [{"productName":"GLM Coding Lite","status":"EXPIRED","inCurrentPeriod":false,"autoRenew":true,"nextRenewTime":"2026-09-01"},
         {"productName":"Something else","status":"VALID","inCurrentPeriod":true,"autoRenew":false},
         {"productName":"GLM Coding Max","status":"VALID","inCurrentPeriod":true,"autoRenew":false,
          "valid":"2026-10-02 18:41:37-2026-12-02 18:41:37"}]
        """
        let list = try JSONDecoder().decode([ZaiSubscription].self, from: Data(json.utf8))
        XCTAssertEqual(ZaiSubscription.currentPlan(in: list),
                       ZaiPlanInfo(productName: "GLM Coding Max", renews: false, date: "2026-12-02"))
        XCTAssertNil(ZaiSubscription.currentPlan(in: Array(list.prefix(2))))
    }

    func test_envelopePayload_rejectsFailures() throws {
        let failed = try JSONDecoder().decode(ZaiEnvelope<[ZaiSubscription]>.self,
                                              from: Data(#"{"code":500,"msg":"404 NOT_FOUND","success":false}"#.utf8))
        XCTAssertNil(failed.payload)
    }

    func test_summarize_withPlanAndResets() throws {
        let resetJSON = """
        {"available_five_hour_resets":[{"expire_at":1791500000000},{"expire_at":1790000000000}],
         "available_week_resets":[{"expire_at":1791200000}],
         "latest_five_hour_reset_history":null,"latest_week_reset_history":null,"has_unread_history":false}
        """
        let resets = try JSONDecoder().decode(ZaiResetStatus.self, from: Data(resetJSON.utf8))
        let usage = try ZaiUsageMapper.summarize(
            try decode(liveResponse), name: "zcode",
            plan: ZaiPlanInfo(productName: "GLM Coding Pro", renews: true, date: "2026-11-02"),
            resets: resets, now: now)
        XCTAssertEqual(usage.plan, "GLM CODING PRO", "product name wins over the bare level")
        XCTAssertEqual(usage.note, "renews Nov 2")
        XCTAssertEqual(usage.resetCredits, 2, "the already-expired grant is not counted")
        XCTAssertEqual(usage.resetCreditsExpireAt, "2026-10-05T11:33:20Z", "seconds-valued expiry accepted too")

        let expiring = try ZaiUsageMapper.summarize(
            try decode(liveResponse), name: "zcode",
            plan: ZaiPlanInfo(productName: "GLM Coding Pro", renews: false, date: "2026-11-02"),
            resets: ZaiResetStatus(availableFiveHourResets: [], availableWeekResets: nil), now: now)
        XCTAssertEqual(expiring.note, "expires Nov 2")
        XCTAssertEqual(expiring.resetCredits, 0)
        XCTAssertNil(expiring.resetCreditsExpireAt)
    }

    func test_sideInfoCache_servesLastGoodValueOnFailure() async {
        let cache = UsageSideInfoCache<String>()
        let start = Date()
        let first = await cache.value(for: "a", ttl: 60, now: start) { "plus" }
        XCTAssertEqual(first, "plus")
        let cached = await cache.value(for: "a", ttl: 60, now: start.addingTimeInterval(30)) {
            XCTFail("within ttl")
            return "x"
        }
        XCTAssertEqual(cached, "plus")
        let stale = await cache.value(for: "a", ttl: 60, now: start.addingTimeInterval(120)) {
            throw ZCodeUsageError("down")
        }
        XCTAssertEqual(stale, "plus")
        let missing = await cache.value(for: "b", ttl: 60, now: start) { throw ZCodeUsageError("down") }
        XCTAssertNil(missing)
    }

    // MARK: - Live smoke test (opt-in)

    /// Reads ZCode's real credential store and hits the quota endpoint. Run
    /// with `TEST_RUNNER_ZCODE_USAGE_INTEGRATION=1`.
    func test_liveFetch() async throws {
        guard ProcessInfo.processInfo.environment["ZCODE_USAGE_INTEGRATION"] == "1" else {
            throw XCTSkip("set TEST_RUNNER_ZCODE_USAGE_INTEGRATION=1 to run")
        }
        let dir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".zcode").path
        let usage = try await ZCodeUsageFetcher().fetch(account: UsageAccountConfig(provider: .zcode, name: "zcode",
                                                                                    configDir: dir))
        XCTAssertEqual(usage.status, "ok")
        XCTAssertFalse(usage.metrics.isEmpty)
        XCTAssertFalse(usage.plan.isEmpty, "plan lookup")
        print("LIVE \(usage.provider.rawValue): plan=\(usage.plan) note=\(usage.note ?? "-") resets=\(usage.resetCredits.map(String.init) ?? "-")")
    }
}
