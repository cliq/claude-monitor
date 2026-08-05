import XCTest
@testable import ClaudeMonitor

final class UsageFormattingTests: XCTestCase {
    // Fixed calendar day so assertions never depend on wall-clock time — both
    // `now` and the reset are built from the same DateComponents.
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

    private func iso(_ date: Date, fractionalSeconds: Bool = false) -> String {
        let fmt = ISO8601DateFormatter()
        fmt.formatOptions = fractionalSeconds
            ? [.withInternetDateTime, .withFractionalSeconds]
            : [.withInternetDateTime]
        return fmt.string(from: date)
    }

    func test_formatReset_sameDayFuture_returnsTimeOnly() {
        let now = fixedDate(hour: 9, minute: 0)
        let reset = fixedDate(hour: 12, minute: 30)
        XCTAssertEqual(UsageFormat.formatReset(iso(reset), now: now), "12:30")
    }

    func test_formatReset_differentDayFuture_includesWeekday() {
        let now = fixedDate(hour: 9, minute: 0)
        let reset = fixedDate(hour: 12, minute: 30, dayOffset: 1)
        let out = UsageFormat.formatReset(iso(reset), now: now)
        XCTAssertTrue(out.range(of: #"^[A-Z][a-z]{2} \d{2}:\d{2}$"#, options: .regularExpression) != nil,
                      "expected 'E HH:mm' format, got '\(out)'")
    }

    func test_formatReset_pastSameDay_returnsEmDash() {
        let now = fixedDate(hour: 12, minute: 30)
        let reset = fixedDate(hour: 9, minute: 0)
        XCTAssertEqual(UsageFormat.formatReset(iso(reset), now: now), "—")
    }

    func test_formatReset_pastPreviousDay_returnsEmDash() {
        let now = fixedDate(hour: 9, minute: 0)
        let reset = fixedDate(hour: 9, minute: 0, dayOffset: -1)
        XCTAssertEqual(UsageFormat.formatReset(iso(reset), now: now), "—")
    }

    func test_formatReset_roundsUpToSameMinuteAsNow_isNotPast() {
        // Reset is 20s after now; rounding to the nearest minute pulls it to
        // the same minute as `now`, so it must NOT be treated as past.
        let now = fixedDate(hour: 9, minute: 0, second: 0)
        let reset = fixedDate(hour: 9, minute: 0, second: 20)
        XCTAssertEqual(UsageFormat.formatReset(iso(reset), now: now), "09:00")
    }

    func test_formatReset_nilIsEmpty() {
        XCTAssertEqual(UsageFormat.formatReset(nil), "")
    }

    func test_formatReset_garbageIsEmpty() {
        XCTAssertEqual(UsageFormat.formatReset("not a date"), "")
    }

    func test_formatReset_acceptsFractionalSeconds() {
        let now = fixedDate(hour: 9, minute: 0)
        let reset = fixedDate(hour: 12, minute: 0)
        XCTAssertEqual(UsageFormat.formatReset(iso(reset, fractionalSeconds: true), now: now), "12:00")
    }

    func test_staleAfter_equalsThreePollIntervals() {
        XCTAssertEqual(UsageFormat.staleAfter, UsagePoller.pollInterval * 3)
    }
}
