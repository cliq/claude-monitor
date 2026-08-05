import Foundation

/// Pure formatting/summarizing helpers for usage data, factored out of
/// `UsagePoller` so they hold no networking/keychain/AppKit dependencies —
/// this is what gets shared into the widget target.
enum UsageFormat {
    /// Must equal `UsagePoller.pollInterval * 3` — the Usage Panel staleness rule.
    nonisolated static let staleAfter: TimeInterval = 540

    nonisolated static func summarize(raw: [String: Any], name: String, plan: String) -> AccountUsage {
        var out = AccountUsage(name: name, status: "ok")
        out.plan = plan.uppercased()

        if let session = raw["five_hour"] as? [String: Any],
           let resets = session["resets_at"] as? String {
            out.sessionPct = Int((session["utilization"] as? Double ?? 0).rounded())
            out.sessionResets = formatReset(resets)
            out.sessionResetsAt = resets
        } // else: idle, keep -1

        if let weekly = raw["seven_day"] as? [String: Any] {
            out.weeklyPct = Int((weekly["utilization"] as? Double ?? 0).rounded())
            let resets = weekly["resets_at"] as? String
            out.weeklyResets = formatReset(resets)
            out.weeklyResetsAt = resets
        }

        // Model-scoped weekly limit (e.g. the Fable cap) lives in the limits list.
        for lim in raw["limits"] as? [[String: Any]] ?? [] {
            guard lim["kind"] as? String == "weekly_scoped",
                  let scope = lim["scope"] as? [String: Any] else { continue }
            let model = (scope["model"] as? [String: Any])?["display_name"] as? String ?? "model"
            out.modelLabel = model.uppercased()
            out.modelPct = lim["percent"] as? Int ?? 0
            let resets = lim["resets_at"] as? String
            out.modelResets = formatReset(resets)
            out.modelResetsAt = resets
            break
        }
        return out
    }

    /// Absolute local reset time: "23:50" if today, else "Fri 12:00". Returns
    /// "—" once the reset has already passed `now` — a reset in the past
    /// means the displayed percentages are stale.
    nonisolated static func formatReset(_ iso: String?, now: Date = Date()) -> String {
        guard let iso else { return "" }
        let parser = ISO8601DateFormatter()
        parser.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        var date = parser.date(from: iso)
        if date == nil {
            parser.formatOptions = [.withInternetDateTime]
            date = parser.date(from: iso)
        }
        guard var d = date else { return "" }
        d = Date(timeIntervalSinceReferenceDate: (d.timeIntervalSinceReferenceDate / 60).rounded() * 60)
        if d < now { return "—" }
        let fmt = DateFormatter()
        fmt.locale = Locale(identifier: "en_US_POSIX")
        fmt.dateFormat = Calendar.current.isDate(d, inSameDayAs: now) ? "HH:mm" : "E HH:mm"
        return fmt.string(from: d)
    }
}
