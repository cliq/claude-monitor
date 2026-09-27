// Widget/UsageEntry.swift
// Shared by the macOS widget and the iOS widget (ClaudeMonitorMobileWidget).
import Foundation
import WidgetKit

struct UsageEntry: TimelineEntry {
    let date: Date
    let snapshot: UsageSnapshot?
}

extension UsageSnapshot {
    /// Synthetic data for the widget gallery / Xcode preview — never touches disk.
    static var placeholderSample: UsageSnapshot {
        let personal = AccountUsage(
            name: "personal",
            status: "ok",
            plan: "MAX",
            sessionPct: 42,
            sessionResets: "14:00",
            weeklyPct: 31,
            weeklyResets: "Fri 09:00",
            modelPct: 18,
            modelResets: "10:00",
            modelLabel: "OPUS"
        )
        let work = AccountUsage(
            name: "work",
            status: "ok",
            plan: "PRO",
            sessionPct: -1,
            weeklyPct: 66,
            weeklyResets: "Mon 00:00"
        )
        let codex = AccountUsage(
            provider: .codex,
            name: "codex",
            status: "ok",
            plan: "PLUS",
            weeklyPct: 25,
            weeklyResets: "Thu 08:00",
            modelPct: 6,
            modelResets: "Mon 00:00",
            modelLabel: "SPEND",
            metrics: [
                UsageMetric(id: "codex:0", label: "WEEKLY", usedPct: 25, resets: "Thu 08:00"),
                UsageMetric(id: "individual", label: "SPEND", usedPct: 6,
                            resets: "Mon 00:00", detail: "125 / 2000 credits"),
            ]
        )
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return UsageSnapshot(updatedAt: formatter.string(from: .now), accounts: [personal, work, codex])
    }
}
