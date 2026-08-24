import Foundation

/// Fetches usage for one Codex account through a short-lived
/// `codex app-server` process (`CodexAppServerClient`), then maps the
/// response onto `AccountUsage` via `CodexUsageMapper`.
struct CodexUsageFetcher: UsageFetching {
    var client = CodexAppServerClient()

    func fetch(account: UsageAccountConfig) async throws -> AccountUsage {
        let result = try await client.fetchRateLimits(codexHome: account.configDir)
        return CodexUsageMapper.summarize(result, name: account.name)
    }
}

/// Pure mapping from the app-server rate-limit response onto the display
/// model. Kept `nonisolated`/static so the table-style tests stay meaningful.
enum CodexUsageMapper {
    /// ~7 days, with tolerance for backend jitter.
    private static let weeklyRangeMins: ClosedRange<Double> = 9000...11500
    /// Windows up to 6 hours count as the session bucket.
    private static let sessionMaxMins: Double = 360

    private enum Kind: Int {
        // Raw value doubles as display priority: session, weekly,
        // monthly/individual (inserted between), other, named extras.
        case session = 0, weekly = 1, other = 3, named = 4
    }

    private struct ClassifiedWindow {
        var metric: UsageMetric
        var durationMins: Double?
        var kind: Kind
    }

    nonisolated static func summarize(_ result: CodexRateLimitsResult, name: String,
                                      now: Date = Date()) -> AccountUsage {
        var out = AccountUsage(provider: .codex, name: name, status: "ok")

        // Prefer the multi-bucket map; fall back to the single legacy snapshot.
        let buckets: [(key: String, snapshot: CodexRateLimitSnapshot)]
        if let byId = result.rateLimitsByLimitId, !byId.isEmpty {
            buckets = byId.sorted { lhs, rhs in
                // The plain "codex" bucket is the primary product allowance.
                if lhs.key == "codex" { return rhs.key != "codex" }
                if rhs.key == "codex" { return false }
                return lhs.key < rhs.key
            }.map { (key: $0.key, snapshot: $0.value) }
        } else if let single = result.rateLimits {
            buckets = [(single.limitId ?? "codex", single)]
        } else {
            buckets = []
        }

        if let plan = buckets.compactMap({ $0.snapshot.planType }).first {
            out.plan = plan.uppercased()
        }

        var windows: [ClassifiedWindow] = []
        for (key, snapshot) in buckets {
            var seen: [CodexRateLimitWindow] = []
            let bucketWindows = [snapshot.primary, snapshot.secondary]
                .compactMap { $0 }
                .filter { window in
                    if seen.contains(window) { return false } // dedup within the bucket
                    seen.append(window)
                    return true
                }
            let bucketName = (snapshot.limitName ?? "").trimmingCharacters(in: .whitespaces)
            for (index, window) in bucketWindows.enumerated() {
                let duration = window.windowDurationMins
                let iso = isoString(unixSeconds: window.resetsAt)
                let kind: Kind
                let label: String
                if !bucketName.isEmpty {
                    kind = .named
                    label = bucketWindows.count > 1
                        ? "\(bucketName.uppercased()) \(durationLabel(duration))"
                        : bucketName.uppercased()
                } else {
                    kind = classify(duration)
                    switch kind {
                    case .session: label = "SESSION"
                    case .weekly:  label = "WEEKLY"
                    default:       label = durationLabel(duration)
                    }
                }
                windows.append(ClassifiedWindow(
                    metric: UsageMetric(id: "\(key):\(index)", label: label,
                                        usedPct: clampPct(window.usedPercent),
                                        resets: UsageFormat.formatReset(iso, now: now),
                                        resetsAt: iso),
                    durationMins: duration, kind: kind))
            }
        }

        // Spend-control ("individual") limit — monthly only when the reset
        // boundary supports that reading; the monitor never redeems credits.
        var individualMetric: UsageMetric?
        if let individual = buckets.compactMap({ $0.snapshot.individualLimit }).first {
            var pct = individual.remainingPercent.map { 100 - $0 }
            if pct == nil, let used = individual.used.flatMap(Double.init),
               let limit = individual.limit.flatMap(Double.init), limit > 0 {
                pct = used / limit * 100
            }
            let iso = isoString(unixSeconds: individual.resetsAt)
            var detail: String?
            if let used = individual.used, let limit = individual.limit {
                detail = "\(cleanAmount(used)) / \(cleanAmount(limit))"
            }
            individualMetric = UsageMetric(
                id: "individual",
                label: isMonthlyBoundary(unixSeconds: individual.resetsAt) ? "MONTHLY" : "INDIVIDUAL",
                usedPct: clampPct(pct),
                resets: UsageFormat.formatReset(iso, now: now),
                resetsAt: iso,
                detail: detail)
        }

        // Priority order: session, weekly, monthly/individual, other
        // unnamed durations, then named extra buckets.
        var metrics: [UsageMetric] = []
        metrics += windows.filter { $0.kind == .session }.map(\.metric)
        metrics += windows.filter { $0.kind == .weekly }.map(\.metric)
        if let individualMetric { metrics.append(individualMetric) }
        metrics += windows.filter { $0.kind == .other }.map(\.metric)
        metrics += windows.filter { $0.kind == .named }.map(\.metric)
        out.metrics = metrics

        // Legacy ESP32 adapter fields. Named buckets are other products'
        // allowances — only unnamed windows feed the flat slots.
        if let weekly = windows.first(where: { $0.kind == .weekly }) {
            out.weeklyPct = weekly.metric.usedPct
            out.weeklyResets = weekly.metric.resets
            out.weeklyResetsAt = weekly.metric.resetsAt
        }
        let sessionCandidates = windows.filter { $0.kind == .session || $0.kind == .other }
        if let shortest = sessionCandidates.min(by: {
            ($0.durationMins ?? .infinity) < ($1.durationMins ?? .infinity)
        }) {
            out.sessionPct = shortest.metric.usedPct
            out.sessionResets = shortest.metric.resets
            out.sessionResetsAt = shortest.metric.resetsAt
        }
        if let individualMetric {
            out.modelPct = individualMetric.usedPct
            out.modelResets = individualMetric.resets
            out.modelResetsAt = individualMetric.resetsAt
            out.modelLabel = individualMetric.label
        }

        // Exhausted state: keep the last valid percentages, surface the reason.
        if buckets.contains(where: { $0.snapshot.spendControlReached == true }) {
            out.status = "error"
            out.error = "spend limit reached"
        } else if buckets.contains(where: { $0.snapshot.rateLimitReachedType != nil }) {
            out.status = "error"
            out.error = "limit reached"
        }
        return out
    }

    // MARK: - Helpers

    private nonisolated static func classify(_ durationMins: Double?) -> Kind {
        guard let durationMins else { return .other }
        if durationMins <= sessionMaxMins { return .session }
        if weeklyRangeMins.contains(durationMins) { return .weekly }
        return .other
    }

    /// Neutral duration-derived label for unnamed non-session/weekly windows —
    /// never a guessed product name.
    nonisolated static func durationLabel(_ durationMins: Double?) -> String {
        guard let mins = durationMins, mins > 0 else { return "LIMIT" }
        if mins < 60 { return "\(Int(mins.rounded())) MIN" }
        if mins < 48 * 60 { return "\(Int((mins / 60).rounded()))H" }
        return "\(Int((mins / 1440).rounded()))D"
    }

    /// Amounts arrive as strings like "0.0" — drop a meaningless fraction for
    /// display, leave anything non-numeric untouched.
    nonisolated static func cleanAmount(_ amount: String) -> String {
        guard let value = Double(amount), value == value.rounded(),
              value.magnitude < Double(Int.max) else { return amount }
        return String(Int(value))
    }

    nonisolated static func clampPct(_ value: Double?) -> Int {
        guard let value else { return 0 }
        return min(100, max(0, Int(value.rounded())))
    }

    nonisolated static func isoString(unixSeconds: Double?) -> String? {
        guard let unixSeconds else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: Date(timeIntervalSince1970: unixSeconds))
    }

    /// True when the reset lands on the first day of a month (UTC) — the only
    /// boundary we're willing to call "monthly" without guessing.
    nonisolated static func isMonthlyBoundary(unixSeconds: Double?) -> Bool {
        guard let unixSeconds else { return false }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar.component(.day, from: Date(timeIntervalSince1970: unixSeconds)) == 1
    }
}
