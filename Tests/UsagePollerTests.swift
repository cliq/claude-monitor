import XCTest
@testable import ClaudeMonitor

final class UsagePollerTests: XCTestCase {
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

    // MARK: - formatReset

    func test_formatReset_nilAndGarbageAreEmpty() {
        XCTAssertEqual(UsagePoller.formatReset(nil), "")
        XCTAssertEqual(UsagePoller.formatReset("not a date"), "")
    }

    func test_formatReset_todayUsesTimeOnly() {
        // Noon today in local time, far enough from midnight that rounding to
        // the minute can't move it to another day.
        let noon = Calendar.current.date(bySettingHour: 12, minute: 30, second: 0, of: Date())!
        let fmt = ISO8601DateFormatter()
        let out = UsagePoller.formatReset(fmt.string(from: noon))
        XCTAssertEqual(out, "12:30")
    }

    func test_formatReset_otherDayIncludesWeekday() {
        let future = Calendar.current.date(byAdding: .day, value: 3, to: Date())!
        let fmt = ISO8601DateFormatter()
        let out = UsagePoller.formatReset(fmt.string(from: future))
        // "E HH:mm" — three-letter weekday, space, time.
        XCTAssertTrue(out.range(of: #"^[A-Z][a-z]{2} \d{2}:\d{2}$"#, options: .regularExpression) != nil,
                      "expected 'E HH:mm' format, got '\(out)'")
    }

    func test_formatReset_acceptsFractionalSeconds() {
        let noon = Calendar.current.date(bySettingHour: 12, minute: 0, second: 0, of: Date())!
        let fmt = ISO8601DateFormatter()
        fmt.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        XCTAssertEqual(UsagePoller.formatReset(fmt.string(from: noon)), "12:00")
    }
}
