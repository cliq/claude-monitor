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
            out.plan = planLabel(plan)
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
                    let short = shortBucketLabel(bucketName)
                    label = bucketWindows.count > 1
                        ? "\(short) \(durationLabel(duration))"
                        : short
                } else {
                    kind = classify(duration)
                    switch kind {
                    case .session: label = "SESSION"
                    case .weekly:  label = "WEEKLY"
                    default:       label = durationLabel(duration)
                    }
                }
                var metric = UsageMetric(id: "\(key):\(index)", label: label,
                                         usedPct: clampPct(window.usedPercent),
                                         resets: UsageFormat.formatReset(iso, now: now),
                                         resetsAt: iso)
                if kind == .named {
                    // Named buckets are optional model allowances the user
                    // can hide per account (Settings → Usage). The cell label
                    // is the short form; the full name rides in the detail.
                    metric.group = key
                    metric.groupLabel = bucketName
                    if shortBucketLabel(bucketName) != bucketName.uppercased() {
                        metric.detail = bucketName
                    }
                }
                windows.append(ClassifiedWindow(metric: metric, durationMins: duration, kind: kind))
            }
        }

        // Spend-control ("individual") limit — Codex's own status card shows
        // it as "<used> of <limit> credits used". The reset date in the
        // footer says how often it refreshes; the monitor never redeems
        // credits.
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
                detail = "\(cleanAmount(used)) / \(cleanAmount(limit)) credits"
            }
            individualMetric = UsageMetric(
                id: "individual",
                label: "SPEND",
                usedPct: clampPct(pct),
                resets: UsageFormat.formatReset(iso, now: now),
                resetsAt: iso,
                detail: detail,
                group: UsageMetricGroup.spendLimitKey,
                groupLabel: "Spend limit")
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

        // Exhausted state: keep the percentages, surface the reason. Only a
        // refusal of ordinary usage (or a hit rate-limit window) is an error.
        // A reached spend cap on its own — Business seats with a zero
        // extra-spend allowance report it permanently while the plan
        // allowance stays usable — is already visible as the 100% SPEND bar.
        let spendCapReached = buckets.contains { $0.snapshot.spendControlReached == true }
        var notes: [String] = []
        if result.ordinaryUsageAllowed == false {
            out.status = "error"
            out.error = spendCapReached ? "spend limit reached" : "usage blocked"
        } else if buckets.contains(where: { $0.snapshot.rateLimitReachedType != nil }) {
            out.status = "error"
            out.error = "limit reached"
        }

        // Purchased/granted credits: only mention a real balance.
        if let credits = buckets.compactMap({ $0.snapshot.credits }).first {
            if credits.unlimited == true {
                notes.append("unlimited credits")
            } else if let balance = credits.balance, let value = Double(balance), value > 0 {
                notes.append("\(cleanAmount(balance)) credits")
            }
        }
        out.note = notes.isEmpty ? nil : notes.joined(separator: " · ")
        out.resetCredits = availableResetCredits(result.rateLimitResetCredits)
        out.resetCreditsExpireAt = isoString(
            unixSeconds: availableResetGrants(result.rateLimitResetCredits)?.compactMap(\.expiresAt).min())
        return out
    }

    /// Count of unredeemed reset grants. Prefers the explicit list (status
    /// "available") and falls back to the server's own count.
    nonisolated static func availableResetCredits(_ credits: CodexResetCredits?) -> Int? {
        guard let credits else { return nil }
        if let grants = availableResetGrants(credits) { return grants.count }
        return credits.availableCount
    }

    private nonisolated static func availableResetGrants(_ credits: CodexResetCredits?) -> [CodexResetCredit]? {
        credits?.credits?.filter { ($0.status ?? "available").lowercased() == "available" }
    }

    // MARK: - Helpers

    /// Display label for the app-server `planType`. Business/enterprise seats
    /// arrive as long snake_case identifiers (`self_serve_business_prolite`)
    /// that truncate in the panel; known ones get the names Codex's own TUI
    /// uses ("Business Premium"; `prolite` is the Pro 5x tier, `pro` the 20x),
    /// anything else is shown verbatim with the
    /// underscores turned into spaces — never a guessed product name.
    nonisolated static func planLabel(_ planType: String) -> String {
        let key = planType.trimmingCharacters(in: .whitespaces).lowercased()
        switch key {
        case "prolite":                         return "PRO 5X"
        case "self_serve_business_prolite":     return "BUSINESS PREMIUM"
        case "self_serve_business_usage_based": return "BUSINESS USAGE-BASED"
        case "enterprise_cbp_automation":       return "ENTERPRISE AUTOMATION"
        case "enterprise_cbp_usage_based":      return "ENTERPRISE USAGE-BASED"
        default:
            return key.replacingOccurrences(of: "_", with: " ").uppercased()
        }
    }

    /// Cell label for a named bucket: the last hyphen-separated part of the
    /// name Codex sends ("GPT-5.3-Codex-Spark" → "SPARK"), because the full
    /// name doesn't fit a metric cell. Falls back to the whole name when the
    /// tail has no letters ("GPT-5" → "GPT-5") — still derived, never guessed.
    nonisolated static func shortBucketLabel(_ name: String) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        let tail = trimmed.split(separator: "-").last.map { String($0).trimmingCharacters(in: .whitespaces) } ?? ""
        guard tail.rangeOfCharacter(from: .letters) != nil else { return trimmed.uppercased() }
        return tail.uppercased()
    }

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

    /// Credit amounts arrive as strings like "0.0" or "1426.6314442157745".
    /// Display them as whole credits; anything non-numeric is left untouched.
    nonisolated static func cleanAmount(_ amount: String) -> String {
        guard let value = Double(amount), value.isFinite,
              value.magnitude < Double(Int.max) else { return amount }
        return String(Int(value.rounded()))
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

}
