import XCTest
@testable import ClaudeMonitor

final class CodexUsageTests: XCTestCase {
    // MARK: - Helpers

    private func decodeResult(_ json: String) throws -> CodexRateLimitsResult {
        try JSONDecoder().decode(CodexRateLimitsResult.self, from: Data(json.utf8))
    }

    private func unixSeconds(_ iso: String) -> Double {
        let parser = ISO8601DateFormatter()
        parser.formatOptions = [.withInternetDateTime]
        return parser.date(from: iso)!.timeIntervalSince1970
    }

    private func responseLine(id: Int, result: String) -> Data {
        Data(#"{"id":\#(id),"result":\#(result)}"#.utf8 + [UInt8(ascii: "\n")])
    }

    private let simpleResult = #"{"rateLimits":{"limitId":"codex","primary":{"usedPercent":25,"windowDurationMins":10080,"resetsAt":1788164537}}}"#

    // MARK: - Response accumulation / correlation

    func test_accumulator_findsResponseAfterNotificationAndOtherIDs() {
        let acc = CodexResponseAccumulator(requestID: 1)
        var chunk = Data(#"{"id":0,"result":{"userAgent":"codex"}}"#.utf8 + [10])
        chunk += Data(#"{"method":"remoteControl/status/changed","params":{}}"#.utf8 + [10])
        chunk += responseLine(id: 1, result: simpleResult)

        guard case .success(let result) = acc.feed(chunk) else {
            return XCTFail("expected success")
        }
        XCTAssertEqual(result.rateLimits?.primary?.usedPercent, 25)
    }

    func test_accumulator_assemblesFragmentedLines() {
        let acc = CodexResponseAccumulator(requestID: 1)
        let line = responseLine(id: 1, result: simpleResult)
        let mid = line.count / 2

        XCTAssertEqual(acc.feed(line.prefix(mid)), .pending)
        guard case .success = acc.feed(line.suffix(from: mid)) else {
            return XCTFail("expected success after second fragment")
        }
    }

    func test_accumulator_skipsMalformedLineThenAcceptsValidResponse() {
        let acc = CodexResponseAccumulator(requestID: 1)
        var chunk = Data("this is not json\n".utf8)
        chunk += responseLine(id: 1, result: simpleResult)
        guard case .success = acc.feed(chunk) else {
            return XCTFail("expected success")
        }
    }

    func test_accumulator_pendingWithoutMatchingResponse() {
        let acc = CodexResponseAccumulator(requestID: 1)
        XCTAssertEqual(acc.feed(Data(#"{"id":0,"result":{}}"#.utf8 + [10])), .pending)
    }

    func test_accumulator_mapsRPCErrors() {
        XCTAssertEqual(CodexResponseAccumulator.mapRPCError(message: "Method not found: account/rateLimits/read"),
                       .methodUnavailable)
        XCTAssertEqual(CodexResponseAccumulator.mapRPCError(message: "API key authentication does not include rate limits"),
                       .apiKeyAuth)
        XCTAssertEqual(CodexResponseAccumulator.mapRPCError(message: "unauthorized"),
                       .notAuthenticated)
        XCTAssertEqual(CodexResponseAccumulator.mapRPCError(message: "something exploded"),
                       .processFailed("something exploded"))
    }

    func test_accumulator_errorResponseSurfacesAsFailure() {
        let acc = CodexResponseAccumulator(requestID: 1)
        let chunk = Data(#"{"id":1,"error":{"code":-32601,"message":"Method not found"}}"#.utf8 + [10])
        XCTAssertEqual(acc.feed(chunk), .failure(.methodUnavailable))
    }

    // MARK: - Wire decoding

    func test_decode_individualLimit_acceptsStringOrNumberAmounts() throws {
        let asStrings = try JSONDecoder().decode(CodexIndividualLimit.self, from: Data(
            #"{"limit":"2000","used":"125","remainingPercent":94,"resetsAt":1788220800}"#.utf8))
        XCTAssertEqual(asStrings.limit, "2000")
        XCTAssertEqual(asStrings.used, "125")

        let asNumbers = try JSONDecoder().decode(CodexIndividualLimit.self, from: Data(
            #"{"limit":2000,"used":125,"remainingPercent":94}"#.utf8))
        XCTAssertEqual(asNumbers.limit, "2000")
        XCTAssertEqual(asNumbers.used, "125")
    }

    // MARK: - Mapping: ordinary windows

    func test_summarize_fiveHourPrimaryAndWeeklySecondary() throws {
        let resetSession = unixSeconds("2026-08-24T18:00:00Z")
        let resetWeekly = unixSeconds("2026-08-28T00:00:00Z")
        let result = try decodeResult("""
        {"rateLimits":{"limitId":"codex","planType":"plus",
          "primary":{"usedPercent":42,"windowDurationMins":300,"resetsAt":\(resetSession)},
          "secondary":{"usedPercent":11,"windowDurationMins":10080,"resetsAt":\(resetWeekly)}}}
        """)

        let out = CodexUsageMapper.summarize(result, name: "codex")
        XCTAssertEqual(out.provider, .codex)
        XCTAssertEqual(out.status, "ok")
        XCTAssertEqual(out.plan, "PLUS")
        XCTAssertEqual(out.metrics.map(\.label), ["SESSION", "WEEKLY"])
        XCTAssertEqual(out.metrics.map(\.usedPct), [42, 11])
        // Legacy adapter slots.
        XCTAssertEqual(out.sessionPct, 42)
        XCTAssertEqual(out.weeklyPct, 11)
        XCTAssertEqual(out.modelPct, -1)
        // Unix seconds became ISO-8601.
        XCTAssertEqual(out.sessionResetsAt, "2026-08-24T18:00:00Z")
        XCTAssertEqual(out.weeklyResetsAt, "2026-08-28T00:00:00Z")
    }

    func test_summarize_weeklyOnlyLeavesSessionIdle() throws {
        let result = try decodeResult("""
        {"rateLimits":{"limitId":"codex",
          "primary":{"usedPercent":25,"windowDurationMins":10080,"resetsAt":1788164537}}}
        """)

        let out = CodexUsageMapper.summarize(result, name: "codex")
        XCTAssertEqual(out.metrics.map(\.label), ["WEEKLY"])
        XCTAssertEqual(out.sessionPct, -1)
        XCTAssertEqual(out.weeklyPct, 25)
    }

    func test_summarize_dedupsIdenticalWindowsInBucket() throws {
        let result = try decodeResult("""
        {"rateLimits":{"limitId":"codex",
          "primary":{"usedPercent":25,"windowDurationMins":10080,"resetsAt":1788164537},
          "secondary":{"usedPercent":25,"windowDurationMins":10080,"resetsAt":1788164537}}}
        """)
        XCTAssertEqual(CodexUsageMapper.summarize(result, name: "codex").metrics.count, 1)
    }

    func test_summarize_clampsOutOfRangePercentages() throws {
        let result = try decodeResult("""
        {"rateLimits":{"limitId":"codex",
          "primary":{"usedPercent":250,"windowDurationMins":300},
          "secondary":{"usedPercent":-5,"windowDurationMins":10080}}}
        """)
        let out = CodexUsageMapper.summarize(result, name: "codex")
        XCTAssertEqual(out.metrics.map(\.usedPct), [100, 0])
    }

    func test_summarize_unknownDurationGetsNeutralLabel() throws {
        let result = try decodeResult("""
        {"rateLimits":{"limitId":"codex",
          "primary":{"usedPercent":10,"windowDurationMins":43200}}}
        """)
        // A 30-day window is neither session nor weekly — duration label only,
        // never a guessed product name.
        XCTAssertEqual(CodexUsageMapper.summarize(result, name: "codex").metrics.map(\.label), ["30D"])
    }

    // MARK: - Mapping: multi-bucket

    func test_summarize_prefersRateLimitsByLimitIdAndKeepsNamedBuckets() throws {
        let result = try decodeResult("""
        {"rateLimits":{"limitId":"stale","primary":{"usedPercent":99,"windowDurationMins":300}},
         "rateLimitsByLimitId":{
           "codex":{"limitId":"codex","planType":"team",
             "primary":{"usedPercent":25,"windowDurationMins":10080,"resetsAt":1788164537}},
           "codex_bengalfox":{"limitId":"codex_bengalfox","limitName":"Bengal Fox",
             "primary":{"usedPercent":3,"windowDurationMins":300,"resetsAt":1788164537},
             "secondary":{"usedPercent":1,"windowDurationMins":10080,"resetsAt":1788164537}}}}
        """)

        let out = CodexUsageMapper.summarize(result, name: "codex")
        // The stale single snapshot is ignored; named-bucket windows come last.
        XCTAssertEqual(out.metrics.map(\.label), ["WEEKLY", "BENGAL FOX 5H", "BENGAL FOX 7D"])
        XCTAssertEqual(out.plan, "TEAM")
        // Named buckets never feed the legacy session/weekly slots.
        XCTAssertEqual(out.sessionPct, -1)
        XCTAssertEqual(out.weeklyPct, 25)
    }

    // MARK: - Mapping: individual (spend-control) limit

    func test_summarize_individualLimit_monthlyWhenResetOnMonthBoundary() throws {
        let reset = unixSeconds("2026-09-01T00:00:00Z")
        let result = try decodeResult("""
        {"rateLimits":{"limitId":"codex","planType":"team",
          "primary":{"usedPercent":25,"windowDurationMins":10080,"resetsAt":1788164537},
          "individualLimit":{"limit":"2000","used":"125","remainingPercent":94,"resetsAt":\(reset)}}}
        """)

        let out = CodexUsageMapper.summarize(result, name: "codex")
        let individual = out.metrics.first { $0.id == "individual" }
        XCTAssertEqual(individual?.label, "MONTHLY")
        XCTAssertEqual(individual?.usedPct, 6) // 100 - 94
        XCTAssertEqual(individual?.detail, "125 / 2000")
        XCTAssertEqual(individual?.resetsAt, "2026-09-01T00:00:00Z")
        // Legacy adapter: monthly rides in the model slot.
        XCTAssertEqual(out.modelPct, 6)
        XCTAssertEqual(out.modelLabel, "MONTHLY")
        // Priority: weekly before individual.
        XCTAssertEqual(out.metrics.map(\.label), ["WEEKLY", "MONTHLY"])
    }

    func test_summarize_individualLimit_fallsBackToIndividualLabelOffBoundary() throws {
        let reset = unixSeconds("2026-09-15T10:30:00Z")
        let result = try decodeResult("""
        {"rateLimits":{"limitId":"codex",
          "individualLimit":{"limit":"2000","used":"125","remainingPercent":94,"resetsAt":\(reset)}}}
        """)
        XCTAssertEqual(CodexUsageMapper.summarize(result, name: "codex").modelLabel, "INDIVIDUAL")
    }

    func test_summarize_individualLimit_cleansFractionlessAmounts() throws {
        let result = try decodeResult("""
        {"rateLimits":{"limitId":"codex",
          "individualLimit":{"limit":"2000","used":"0.0","remainingPercent":100}}}
        """)
        let out = CodexUsageMapper.summarize(result, name: "codex")
        XCTAssertEqual(out.metrics.first { $0.id == "individual" }?.detail, "0 / 2000")

        XCTAssertEqual(CodexUsageMapper.cleanAmount("125.5"), "125.5") // real fraction kept
        XCTAssertEqual(CodexUsageMapper.cleanAmount("n/a"), "n/a")     // non-numeric untouched
    }

    func test_summarize_individualLimit_computesPctFromAmountsWhenRemainingMissing() throws {
        let result = try decodeResult("""
        {"rateLimits":{"limitId":"codex",
          "individualLimit":{"limit":"2000","used":"500"}}}
        """)
        XCTAssertEqual(CodexUsageMapper.summarize(result, name: "codex").modelPct, 25)
    }

    // MARK: - Mapping: exhausted / error states

    func test_summarize_spendControlReachedSurfacesErrorWithoutDroppingMetrics() throws {
        let result = try decodeResult("""
        {"rateLimits":{"limitId":"codex","spendControlReached":true,
          "primary":{"usedPercent":100,"windowDurationMins":10080,"resetsAt":1788164537}}}
        """)
        let out = CodexUsageMapper.summarize(result, name: "codex")
        XCTAssertEqual(out.status, "error")
        XCTAssertEqual(out.error, "spend limit reached")
        XCTAssertEqual(out.weeklyPct, 100) // percentages kept
    }

    func test_summarize_rateLimitReachedSurfacesError() throws {
        let result = try decodeResult("""
        {"rateLimits":{"limitId":"codex","rateLimitReachedType":"primary",
          "primary":{"usedPercent":100,"windowDurationMins":300}}}
        """)
        let out = CodexUsageMapper.summarize(result, name: "codex")
        XCTAssertEqual(out.status, "error")
        XCTAssertEqual(out.error, "limit reached")
    }

    func test_summarize_emptyResultIsIdleNotCrash() throws {
        let out = CodexUsageMapper.summarize(try decodeResult("{}"), name: "codex")
        XCTAssertEqual(out.status, "ok")
        XCTAssertTrue(out.metrics.isEmpty)
        XCTAssertEqual(out.sessionPct, -1)
    }

    // MARK: - Error descriptions (plan's display table)

    func test_errorDescriptions_matchDisplayTable() {
        XCTAssertEqual(CodexUsageError.executableNotFound.errorDescription, "Codex CLI not found")
        XCTAssertEqual(CodexUsageError.methodUnavailable.errorDescription, "Update Codex to track usage")
        XCTAssertEqual(CodexUsageError.apiKeyAuth.errorDescription, "ChatGPT login required for plan limits")
        XCTAssertEqual(CodexUsageError.notAuthenticated.errorDescription, "Sign in to Codex again")
        XCTAssertEqual(CodexUsageError.timeout.errorDescription, "Codex usage request failed")
        XCTAssertEqual(CodexUsageError.processFailed("x").errorDescription, "Codex usage request failed")
    }

    // MARK: - Executable discovery

    func test_resolveExecutable_prefersPATHThenCommonLocations() {
        let found = CodexAppServerClient.resolveExecutable(
            environment: ["PATH": "/nowhere:/somewhere/bin"],
            home: "/Users/tester",
            isExecutable: { $0 == "/somewhere/bin/codex" },
            loginShellFallback: { XCTFail("should not reach fallback"); return nil })
        XCTAssertEqual(found, "/somewhere/bin/codex")

        let homebrew = CodexAppServerClient.resolveExecutable(
            environment: ["PATH": "/nowhere"],
            home: "/Users/tester",
            isExecutable: { $0 == "/opt/homebrew/bin/codex" },
            loginShellFallback: { XCTFail("should not reach fallback"); return nil })
        XCTAssertEqual(homebrew, "/opt/homebrew/bin/codex")
    }

    func test_resolveExecutable_usesLoginShellFallbackLast() {
        let found = CodexAppServerClient.resolveExecutable(
            environment: [:],
            home: "/Users/tester",
            isExecutable: { _ in false },
            loginShellFallback: { "/from/login/shell/codex" })
        XCTAssertEqual(found, "/from/login/shell/codex")
    }

    // MARK: - Opt-in integration smoke test

    /// Runs the real installed Codex app-server. Asserts only structural
    /// properties — never prints the response or asserts real percentages,
    /// plan, credits, or reset times. Enable with CODEX_USAGE_INTEGRATION=1.
    func test_integration_fetchRateLimitsFromInstalledCodex() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["CODEX_USAGE_INTEGRATION"] == "1",
                          "set CODEX_USAGE_INTEGRATION=1 to run")
        let home = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex").path
        let result = try await CodexAppServerClient().fetchRateLimits(codexHome: home)
        XCTAssertTrue(result.rateLimits != nil || !(result.rateLimitsByLimitId ?? [:]).isEmpty)
    }
}
