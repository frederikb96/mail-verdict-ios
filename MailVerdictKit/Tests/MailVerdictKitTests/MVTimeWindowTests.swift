import XCTest
@testable import MailVerdictKit

final class MVTimeWindowTests: XCTestCase {

    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Berlin")!
        return calendar
    }

    /// Mid-afternoon on a Monday, local time.
    private var now: Date {
        calendar.date(from: DateComponents(year: 2026, month: 10, day: 12, hour: 15, minute: 30))!
    }

    private func day(_ string: String) -> MVCalendarDay { MVCalendarDay(isoString: string, calendar: calendar)! }

    private func midnight(_ string: String) -> Date { day(string).startOfDay(in: calendar)! }

    func testPresetsResolveAgainstTheGivenNow() {
        let today = MVTimeWindow.preset(.today).bounds(now: now, calendar: calendar)
        XCTAssertEqual(today.since, midnight("2026-10-12"))
        XCTAssertEqual(today.until, now)

        let yesterday = MVTimeWindow.preset(.sinceYesterday).bounds(now: now, calendar: calendar)
        XCTAssertEqual(yesterday.since, midnight("2026-10-11"))

        let week = MVTimeWindow.preset(.last7Days).bounds(now: now, calendar: calendar)
        XCTAssertEqual(week.since, now.addingTimeInterval(-7 * 86_400))
        XCTAssertEqual(week.until, now)

        let month = MVTimeWindow.preset(.last30Days).bounds(now: now, calendar: calendar)
        XCTAssertEqual(month.since, now.addingTimeInterval(-30 * 86_400))
    }

    func testTheSliderAxisIsFiftyTwoWeeksOfLocalMidnights() {
        XCTAssertEqual(MVTimeWindow.sliderDate(stop: 52, now: now, calendar: calendar), midnight("2026-10-12"))
        XCTAssertEqual(MVTimeWindow.sliderDate(stop: 51, now: now, calendar: calendar), midnight("2026-10-05"))
        XCTAssertEqual(MVTimeWindow.sliderDate(stop: 0, now: now, calendar: calendar), midnight("2025-10-13"))
    }

    func testASliderSelectionBecomesWholeDaysAndTheLastStopMeansNow() {
        XCTAssertEqual(
            MVTimeWindow.slider(startStop: 0, endStop: 52, now: now, calendar: calendar),
            .slider(since: day("2025-10-13"), until: nil))
        XCTAssertEqual(
            MVTimeWindow.slider(startStop: 10, endStop: 40, now: now, calendar: calendar),
            .slider(since: day("2025-12-22"), until: day("2026-07-20")))
    }

    func testASliderSelectionKeepsAGapAndStaysOnTheAxis() {
        XCTAssertEqual(
            MVTimeWindow.slider(startStop: 30, endStop: 30, now: now, calendar: calendar).sliderSelection(
                now: now, calendar: calendar), 30...31)
        XCTAssertEqual(
            MVTimeWindow.slider(startStop: 52, endStop: 60, now: now, calendar: calendar).sliderSelection(
                now: now, calendar: calendar), 51...52)
        XCTAssertEqual(
            MVTimeWindow.slider(startStop: -4, endStop: 9, now: now, calendar: calendar).sliderSelection(
                now: now, calendar: calendar), 0...9)
    }

    func testOnlyASliderWindowHasItsOwnSelectionAndAnythingElseShowsTheFullAxis() {
        XCTAssertEqual(MVTimeWindow.preset(.today).sliderSelection(now: now, calendar: calendar), 0...52)
        XCTAssertEqual(
            MVTimeWindow.custom(since: day("2026-01-05"), until: day("2026-02-09")).sliderSelection(
                now: now, calendar: calendar), 0...52)
    }

    func testAnEndedSliderWindowCoversItsLastDayWhole() {
        let window = MVTimeWindow.slider(since: day("2026-03-02"), until: day("2026-03-30"))
        let bounds = window.bounds(now: now, calendar: calendar)
        XCTAssertEqual(bounds.since, midnight("2026-03-02"))
        XCTAssertGreaterThan(bounds.until, midnight("2026-03-30").addingTimeInterval(23 * 3600))
        XCTAssertLessThan(bounds.until, midnight("2026-03-31"))
    }

    func testAnOpenSliderWindowRunsToNow() {
        let bounds = MVTimeWindow.slider(since: day("2026-03-02"), until: nil).bounds(now: now, calendar: calendar)
        XCTAssertEqual(bounds.until, now)
    }

    func testACustomRangeCoversBothEndDaysWhole() {
        let bounds = MVTimeWindow.custom(since: day("2026-03-01"), until: day("2026-03-31")).bounds(
            now: now, calendar: calendar)
        XCTAssertEqual(bounds.since, midnight("2026-03-01"))
        XCTAssertGreaterThan(bounds.until, midnight("2026-03-31").addingTimeInterval(23 * 3600))
        XCTAssertLessThan(bounds.until, midnight("2026-04-01"))
    }

    func testLabelsAreYearMonthDay() {
        XCTAssertEqual(MVTimeWindow.preset(.last7Days).label, "Last 7 days")
        XCTAssertEqual(MVTimeWindow.slider(since: day("2025-10-13"), until: nil).label, "2025-10-13 – now")
        XCTAssertEqual(
            MVTimeWindow.slider(since: day("2025-10-13"), until: day("2026-04-13")).label,
            "2025-10-13 – 2026-04-13")
        XCTAssertEqual(
            MVTimeWindow.custom(since: day("2026-01-05"), until: day("2026-02-09")).label, "2026-01-05 – 2026-02-09")
    }

    func testDayParsingIsStrictIsoOrder() {
        XCTAssertEqual(MVCalendarDay(isoString: "2026-02-28", calendar: calendar)?.description, "2026-02-28")
        XCTAssertNil(MVCalendarDay(isoString: "28-02-2026", calendar: calendar))
        XCTAssertNil(MVCalendarDay(isoString: "2026-2-8", calendar: calendar))
        XCTAssertNil(MVCalendarDay(isoString: "2026-02-30", calendar: calendar))
        XCTAssertNil(MVCalendarDay(isoString: "2026-13-01", calendar: calendar))
        XCTAssertNil(MVCalendarDay(isoString: "", calendar: calendar))
    }

    func testMonthMarksLabelTheFirstWeekOfEachMonth() {
        let marks = MVTimeWindow.monthMarks(now: now, calendar: calendar)
        XCTAssertEqual(marks.count, 12)
        XCTAssertEqual(marks.first, .init(stop: 3, label: "Nov"))
        XCTAssertEqual(marks.last, .init(stop: 51, label: "Oct"))
        XCTAssertEqual(marks.map(\.stop), marks.map(\.stop).sorted())
    }

    func testAWindowSurvivesPersistence() throws {
        let windows: [MVTimeWindow] = [
            .preset(.today), .slider(since: day("2026-01-05"), until: nil),
            .custom(since: day("2026-01-05"), until: day("2026-02-09")),
        ]
        for window in windows {
            let data = try JSONEncoder().encode(window)
            XCTAssertEqual(try JSONDecoder().decode(MVTimeWindow.self, from: data), window)
        }
    }
}
