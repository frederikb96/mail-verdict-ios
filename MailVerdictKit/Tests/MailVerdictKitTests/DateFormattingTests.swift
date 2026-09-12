import XCTest
@testable import MailVerdictKit

final class DateFormattingTests: XCTestCase {

    private let calendar: Calendar = {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        return cal
    }()

    private func date(_ iso: String) -> Date {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: iso)!
    }

    func testNilDateIsEmpty() {
        XCTAssertEqual(MVDateFormat.relativeDate(nil), "")
    }

    func testTodayShowsTheTime() {
        let now = date("2026-03-10T18:00:00Z")
        XCTAssertEqual(MVDateFormat.relativeDate(date("2026-03-10T09:05:00Z"), now: now, calendar: calendar), "09:05")
    }

    func testYesterdayReadsAsYesterday() {
        let now = date("2026-03-10T18:00:00Z")
        XCTAssertEqual(
            MVDateFormat.relativeDate(date("2026-03-09T09:05:00Z"), now: now, calendar: calendar), "Yesterday")
    }

    func testWithinTheLastWeekShowsTheWeekday() {
        let now = date("2026-03-10T18:00:00Z")
        XCTAssertEqual(MVDateFormat.relativeDate(date("2026-03-06T09:05:00Z"), now: now, calendar: calendar), "Fri")
    }

    func testOlderThanAWeekInTheSameYearShowsDayAndMonth() {
        let now = date("2026-03-10T18:00:00Z")
        XCTAssertEqual(MVDateFormat.relativeDate(date("2026-01-02T09:05:00Z"), now: now, calendar: calendar), "2 Jan")
    }

    func testADifferentYearAppendsIt() {
        let now = date("2026-03-10T18:00:00Z")
        XCTAssertEqual(
            MVDateFormat.relativeDate(date("2025-01-02T09:05:00Z"), now: now, calendar: calendar), "2 Jan 2025")
    }

    /// A date after today (spam routinely dates itself ahead) is always the plain date, never a
    /// bare weekday that would pass for one in the past week.
    func testAFutureDateIsAlwaysThePlainDateNeverAWeekday() {
        let now = date("2026-03-10T18:00:00Z")
        XCTAssertEqual(MVDateFormat.relativeDate(date("2026-03-12T09:05:00Z"), now: now, calendar: calendar), "12 Mar")
    }

    func testRelativeAgoUnderAMinuteReadsAsJustNow() {
        let now = date("2026-03-10T18:00:30Z")
        XCTAssertEqual(MVDateFormat.relativeAgo(date("2026-03-10T18:00:00Z"), now: now, calendar: calendar), "just now")
    }

    func testRelativeAgoUnderAnHourShowsMinutes() {
        let now = date("2026-03-10T18:20:00Z")
        XCTAssertEqual(MVDateFormat.relativeAgo(date("2026-03-10T18:00:00Z"), now: now, calendar: calendar), "20m ago")
    }

    func testRelativeAgoOverAnHourFallsBackToRelativeDate() {
        let now = date("2026-03-10T20:00:00Z")
        XCTAssertEqual(MVDateFormat.relativeAgo(date("2026-03-10T09:05:00Z"), now: now, calendar: calendar), "09:05")
    }

    func testFullDateIsWeekdayDayMonthYearAndTime() {
        XCTAssertEqual(MVDateFormat.fullDate(date("2026-03-10T09:05:00Z")), "Tue, 10 Mar 2026, 09:05")
    }

    func testFullDateOfNilIsEmpty() {
        XCTAssertEqual(MVDateFormat.fullDate(nil), "")
    }

    func testFormatSizeZeroAndNil() {
        XCTAssertEqual(formatSize(nil), "0 B")
        XCTAssertEqual(formatSize(0), "0 B")
    }

    func testFormatSizeScalesUnits() {
        XCTAssertEqual(formatSize(512), "512 B")
        XCTAssertEqual(formatSize(2048), "2.0 KB")
        XCTAssertEqual(formatSize(5 * 1024 * 1024), "5.0 MB")
    }
}
