import XCTest
@testable import ClaudeMonitor

final class KimiUsageTests: XCTestCase {
    private var home: URL!
    private let now = Date(timeIntervalSince1970: 1_790_000_000)

    override func setUpWithError() throws {
        home = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("claude-monitor-kimi-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: home.appendingPathComponent("credentials"),
                                                withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: home)
    }

    // MARK: - config.toml

    private let globalConfig = """
    default_model = "kimi-code/k3"

    [providers."managed:kimi-code"]
    type = "kimi"
    api_key = ""
    base_url = "https://api.kimi.ai/coding/v1"

    [providers."managed:kimi-code".oauth]
    storage = "file"
    key = "oauth/kimi-code-env-0e4f99c69cc27850"
    oauth_host = "https://auth.kimi.ai"

    [services.moonshot_search]
    base_url = "https://api.kimi.ai/coding/v1/search"

    [services.moonshot_search.oauth]
    key = "oauth/other"
    """

    func test_parse_readsOnlyTheManagedProvider() {
        let parsed = KimiCodeConfig.parse(toml: globalConfig)
        XCTAssertEqual(parsed, .init(baseURL: "https://api.kimi.ai/coding/v1",
                                     oauthKey: "oauth/kimi-code-env-0e4f99c69cc27850",
                                     oauthHost: "https://auth.kimi.ai"))
    }

    func test_resolve_usesConfiguredSlotAndHosts() throws {
        try globalConfig.write(to: home.appendingPathComponent("config.toml"), atomically: true, encoding: .utf8)
        let login = try KimiCodeConfig.resolve(home: home)
        XCTAssertEqual(login.credentialName, "kimi-code-env-0e4f99c69cc27850")
        XCTAssertEqual(login.baseURL.absoluteString, "https://api.kimi.ai/coding/v1")
        XCTAssertEqual(login.oauthHost.absoluteString, "https://auth.kimi.ai")
        XCTAssertEqual(login.credentialsFile.lastPathComponent, "kimi-code-env-0e4f99c69cc27850.json")
        XCTAssertEqual(login.lockDir.lastPathComponent, "kimi-code-env-0e4f99c69cc27850.lock")
        XCTAssertEqual(login.lockDir.deletingLastPathComponent().lastPathComponent, "oauth")
    }

    func test_resolve_withoutConfig_fallsBackToRegionAndSingleCredentialFile() throws {
        try "global\n".write(to: home.appendingPathComponent("region"), atomically: true, encoding: .utf8)
        try "{}".write(to: home.appendingPathComponent("credentials/kimi-code-env-abc.json"),
                       atomically: true, encoding: .utf8)
        let login = try KimiCodeConfig.resolve(home: home)
        XCTAssertEqual(login.credentialName, "kimi-code-env-abc")
        XCTAssertEqual(login.oauthHost.absoluteString, KimiCodeConfig.globalOAuthHost)
        XCTAssertEqual(login.baseURL.absoluteString, KimiCodeConfig.globalBaseURL)
    }

    func test_resolve_customSlotWithoutHost_followsRegionMarker_defaultSlotStaysMainland() throws {
        try "global".write(to: home.appendingPathComponent("region"), atomically: true, encoding: .utf8)
        try """
        [providers."managed:kimi-code".oauth]
        key = "oauth/kimi-code-env-abc"
        """.write(to: home.appendingPathComponent("config.toml"), atomically: true, encoding: .utf8)
        XCTAssertEqual(try KimiCodeConfig.resolve(home: home).oauthHost.absoluteString, KimiCodeConfig.globalOAuthHost)

        try """
        [providers."managed:kimi-code".oauth]
        key = "oauth/kimi-code"
        """.write(to: home.appendingPathComponent("config.toml"), atomically: true, encoding: .utf8)
        XCTAssertEqual(try KimiCodeConfig.resolve(home: home).oauthHost.absoluteString, KimiCodeConfig.mainlandOAuthHost)
    }

    func test_resolve_defaultsToMainland() throws {
        let login = try KimiCodeConfig.resolve(home: home)
        XCTAssertEqual(login.credentialName, "kimi-code")
        XCTAssertEqual(login.oauthHost.absoluteString, KimiCodeConfig.mainlandOAuthHost)
        XCTAssertEqual(login.baseURL.absoluteString, KimiCodeConfig.mainlandBaseURL)
    }

    func test_resolve_rejectsPathLikeSlotsAndPlainHTTP() throws {
        try """
        [providers."managed:kimi-code".oauth]
        key = "oauth/../../etc/passwd"
        """.write(to: home.appendingPathComponent("config.toml"), atomically: true, encoding: .utf8)
        XCTAssertThrowsError(try KimiCodeConfig.resolve(home: home))

        try """
        [providers."managed:kimi-code"]
        base_url = "http://api.kimi.ai/coding/v1"
        """.write(to: home.appendingPathComponent("config.toml"), atomically: true, encoding: .utf8)
        XCTAssertThrowsError(try KimiCodeConfig.resolve(home: home))
    }

    // MARK: - Mapping

    private func decode(_ json: String) throws -> KimiUsagesResponse {
        try JSONDecoder().decode(KimiUsagesResponse.self, from: Data(json.utf8))
    }

    /// Shape observed from the live endpoint (no weekly window on this plan).
    private let liveResponse = """
    {"limits":[{"window":{"duration":300,"timeUnit":"TIME_UNIT_MINUTE"},"detail":{"limit":"100","remaining":"100","resetTime":"2026-10-02T17:35:45.292491Z"}}],
     "usages":{"limit_5h":{"used_ratio":0,"reset_time":"2026-10-02T17:35:44Z"},
               "limit_month_total":{"used_ratio":0.0752,"reset_time":"2026-10-28T00:00:00Z"},
               "limit_month_code":{"used_ratio":0,"reset_time":"2026-10-28T00:00:00Z"}}}
    """

    func test_summarize_liveShape_withoutWeekly() throws {
        let usage = KimiUsageMapper.summarize(try decode(liveResponse), name: "kimi", planName: "Plus", now: now)
        XCTAssertEqual(usage.provider, .kimi)
        XCTAssertEqual(usage.plan, "PLUS")
        XCTAssertEqual(usage.status, "ok")
        XCTAssertEqual(usage.metrics.map(\.label), ["SESSION", "MONTH"])
        XCTAssertEqual(usage.metrics.map(\.usedPct), [0, 8])
        XCTAssertEqual(usage.metrics[1].detail, "code 0% · kimi 8%")
        XCTAssertEqual(usage.metrics[1].resetsAt, "2026-10-28T00:00:00Z")
        XCTAssertEqual(usage.sessionPct, 0)
        XCTAssertEqual(usage.sessionResetsAt, "2026-10-02T17:35:44Z")
        XCTAssertEqual(usage.weeklyResetsAt, nil, "no weekly window is not invented")
        XCTAssertEqual(usage.modelLabel, "MONTH")
        XCTAssertEqual(usage.modelPct, 8)
        XCTAssertNil(usage.note)
    }

    func test_summarize_allWindows_stringRatios_fractionalResets_andBooster() throws {
        let json = """
        {"usages":{"limit_5h":{"used_ratio":"0.5","reset_time":"2026-10-02T17:35:44.123Z"},
                   "limit_7d":{"used_ratio":0.25,"reset_time":"2026-10-05T00:00:00Z"},
                   "limit_month_total":{"used_ratio":0.6},
                   "limit_month_code":{"used_ratio":0.4}},
         "boosterWallet":{"balance":{"type":"BOOSTER","amount":"5000000000","amountLeft":1234000000},
                          "monthlyChargeLimit":{"priceInCents":0,"currency":"USD"}}}
        """
        let usage = KimiUsageMapper.summarize(try decode(json), name: "kimi", now: now)
        XCTAssertEqual(usage.metrics.map(\.label), ["SESSION", "WEEKLY", "MONTH"])
        XCTAssertEqual(usage.metrics.map(\.usedPct), [50, 25, 60])
        XCTAssertEqual(usage.metrics[0].resetsAt, "2026-10-02T17:35:44Z")
        XCTAssertEqual(usage.metrics[2].detail, "code 40% · kimi 20%")
        XCTAssertEqual(usage.weeklyPct, 25)
        XCTAssertEqual(usage.weeklyResetsAt, "2026-10-05T00:00:00Z")
        XCTAssertEqual(usage.note, "booster $12.34")
    }

    func test_summarize_emptyPayload_hasNoMetrics() throws {
        let usage = KimiUsageMapper.summarize(try decode("{}"), name: "kimi", now: now)
        XCTAssertEqual(usage.metrics, [])
        XCTAssertEqual(usage.status, "ok")
    }

    // MARK: - Token refresh

    func test_needsRefresh_matchesCLIThreshold() {
        let base = now.timeIntervalSince1970
        XCTAssertFalse(KimiToken(accessToken: "a", refreshToken: "r", expiresAt: base + 500, expiresIn: 900)
            .needsRefresh(now: now), "threshold is max(300, 900/2) = 450s")
        XCTAssertTrue(KimiToken(accessToken: "a", refreshToken: "r", expiresAt: base + 400, expiresIn: 900)
            .needsRefresh(now: now))
        XCTAssertTrue(KimiToken(accessToken: "a", refreshToken: "r", expiresAt: base + 299, expiresIn: 0)
            .needsRefresh(now: now))
        XCTAssertFalse(KimiToken(accessToken: "a", refreshToken: "r", expiresAt: 0, expiresIn: 900)
            .needsRefresh(now: now), "expires_at 0 never refreshes")
    }

    func test_tokenResponse_mapping() throws {
        let token = try KimiOAuth.token(status: 200, json: [
            "access_token": "new-a", "refresh_token": "new-r", "expires_in": 900,
            "scope": "kimi-code", "token_type": "Bearer",
        ], now: now)
        XCTAssertEqual(token, KimiToken(accessToken: "new-a", refreshToken: "new-r",
                                        expiresAt: now.timeIntervalSince1970 + 900,
                                        scope: "kimi-code", tokenType: "Bearer", expiresIn: 900))

        for (status, json) in [(401, [String: Any]()), (403, [:]), (400, ["error": "invalid_grant"])] {
            XCTAssertThrowsError(try KimiOAuth.token(status: status, json: json, now: now)) { error in
                guard case KimiTokenStore.RefreshFailure.unauthorized = error else {
                    return XCTFail("HTTP \(status) should be unauthorized, got \(error)")
                }
            }
        }
        XCTAssertThrowsError(try KimiOAuth.token(status: 500, json: [:], now: now)) { error in
            XCTAssertTrue(error is KimiUsageError)
        }
    }

    private func makeStore() throws -> KimiTokenStore {
        let login = try KimiCodeConfig.resolve(home: home)
        return KimiTokenStore(login: login, now: { [now] in now })
    }

    private func writeToken(_ token: KimiToken, store: KimiTokenStore) throws {
        try JSONEncoder().encode(token).write(to: store.login.credentialsFile)
    }

    private var expiring: KimiToken {
        KimiToken(accessToken: "old-a", refreshToken: "old-r",
                  expiresAt: now.timeIntervalSince1970 + 60, scope: "kimi-code", expiresIn: 900)
    }

    private var refreshed: KimiToken {
        KimiToken(accessToken: "new-a", refreshToken: "new-r",
                  expiresAt: now.timeIntervalSince1970 + 900, scope: "kimi-code", expiresIn: 900)
    }

    func test_freshAccessToken_validTokenSkipsRefresh() async throws {
        let store = try makeStore()
        try writeToken(KimiToken(accessToken: "a", refreshToken: "r",
                                 expiresAt: now.timeIntervalSince1970 + 800, expiresIn: 900), store: store)
        let token = try await store.freshAccessToken { _ in
            XCTFail("must not refresh")
            return self.refreshed
        }
        XCTAssertEqual(token, "a")
    }

    func test_freshAccessToken_refreshesUnderLockAndWritesBack() async throws {
        let store = try makeStore()
        try writeToken(expiring, store: store)
        var sentRefreshToken: String?
        let token = try await store.freshAccessToken { refreshToken in
            sentRefreshToken = refreshToken
            XCTAssertTrue(FileManager.default.fileExists(atPath: store.login.lockDir.path),
                          "refresh runs while holding the CLI's lock")
            return self.refreshed
        }
        XCTAssertEqual(token, "new-a")
        XCTAssertEqual(sentRefreshToken, "old-r")
        XCTAssertEqual(try store.load(), refreshed, "rotated refresh token is persisted")
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.login.lockDir.path), "lock released")
        let mode = try FileManager.default.attributesOfItem(atPath: store.login.credentialsFile.path)[.posixPermissions]
        XCTAssertEqual((mode as? NSNumber)?.intValue, 0o600)
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: home.appendingPathComponent("credentials").path)
        XCTAssertEqual(leftovers, [store.login.credentialsFile.lastPathComponent], "no temp files left behind")
    }

    func test_freshAccessToken_liveLockHeld_usesStillValidTokenOrThrows() async throws {
        let store = try makeStore()
        try FileManager.default.createDirectory(at: store.login.lockDir, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.modificationDate: now], ofItemAtPath: store.login.lockDir.path)

        try writeToken(expiring, store: store)
        let stillValid = try await store.freshAccessToken { _ in
            XCTFail("must not refresh while a CLI holds the lock")
            return self.refreshed
        }
        XCTAssertEqual(stillValid, "old-a")

        var expired = expiring
        expired.expiresAt = now.timeIntervalSince1970 - 1
        try writeToken(expired, store: store)
        do {
            _ = try await store.freshAccessToken { _ in self.refreshed }
            XCTFail("expected an error")
        } catch {
            XCTAssertTrue(error is KimiUsageError)
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.login.lockDir.path),
                      "someone else's lock is left alone")
    }

    func test_freshAccessToken_reclaimsStaleLock() async throws {
        let store = try makeStore()
        try FileManager.default.createDirectory(at: store.login.lockDir, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.modificationDate: now.addingTimeInterval(-60)],
                                              ofItemAtPath: store.login.lockDir.path)
        try writeToken(expiring, store: store)
        let token = try await store.freshAccessToken { _ in self.refreshed }
        XCTAssertEqual(token, "new-a")
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.login.lockDir.path))
    }

    func test_freshAccessToken_rejectedRefresh_adoptsTokenRotatedElsewhere() async throws {
        let store = try makeStore()
        try writeToken(expiring, store: store)
        let token = try await store.freshAccessToken { _ in
            // A lock-less refresher won the rotation before our request landed.
            try self.writeToken(self.refreshed, store: store)
            throw KimiTokenStore.RefreshFailure.unauthorized
        }
        XCTAssertEqual(token, "new-a")
    }

    func test_freshAccessToken_rejectedRefresh_neverTombstonesTheLogin() async throws {
        let store = try makeStore()
        try writeToken(expiring, store: store)
        do {
            _ = try await store.freshAccessToken { _ in throw KimiTokenStore.RefreshFailure.unauthorized }
            XCTFail("expected an error")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("kimi login"))
        }
        XCTAssertEqual(try store.load(), expiring, "the CLI decides whether to log out, not the monitor")
    }

    func test_freshAccessToken_revokedTombstone_isReported() async throws {
        let store = try makeStore()
        try writeToken(KimiToken(accessToken: "", refreshToken: "", expiresAt: 0, expiresIn: 0), store: store)
        do {
            _ = try await store.freshAccessToken { _ in self.refreshed }
            XCTFail("expected an error")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("revoked"))
        }
    }

    // MARK: - Live smoke test (opt-in)

    /// Hits the real endpoint with the user's Kimi Code login — refreshing and
    /// rotating the stored token when it is due. Run with
    /// `TEST_RUNNER_KIMI_USAGE_INTEGRATION=1`.
    func test_liveFetch() async throws {
        guard ProcessInfo.processInfo.environment["KIMI_USAGE_INTEGRATION"] == "1" else {
            throw XCTSkip("set TEST_RUNNER_KIMI_USAGE_INTEGRATION=1 to run")
        }
        let dir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".kimi-code").path
        let usage = try await KimiUsageFetcher().fetch(account: UsageAccountConfig(provider: .kimi, name: "kimi",
                                                                                   configDir: dir))
        XCTAssertEqual(usage.status, "ok")
        XCTAssertFalse(usage.metrics.isEmpty)
        XCTAssertFalse(usage.plan.isEmpty, "plan lookup")
        print("LIVE \(usage.provider.rawValue): plan=\(usage.plan) note=\(usage.note ?? "-") resets=\(usage.resetCredits.map(String.init) ?? "-")")
    }
}
