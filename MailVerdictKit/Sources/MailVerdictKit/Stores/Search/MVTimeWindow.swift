import Foundation

/// A calendar day with no time or zone, entered and shown year-month-day (`2026-10-12`) whatever
/// the device's locale or calendar says — the date order the time window's custom range and slider
/// labels always use.
public struct MVCalendarDay: Hashable, Codable, Sendable, Comparable, CustomStringConvertible {
    public let year: Int
    public let month: Int
    public let day: Int

    public init(year: Int, month: Int, day: Int) {
        self.year = year
        self.month = month
        self.day = day
    }

    /// The day `date` falls on in `calendar`'s time zone, always in the Gregorian calendar so a
    /// device set to another calendar system still shows ISO years.
    public init(_ date: Date, calendar: Calendar = .current) {
        let parts = Self.gregorian(in: calendar).dateComponents([.year, .month, .day], from: date)
        self.init(year: parts.year ?? 1970, month: parts.month ?? 1, day: parts.day ?? 1)
    }

    /// Strict `YYYY-MM-DD`: four, two and two digits, and a day that exists.
    public init?(isoString: String, calendar: Calendar = .current) {
        let parts = isoString.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 3, parts[0].count == 4, parts[1].count == 2, parts[2].count == 2,
            parts.allSatisfy({ $0.allSatisfy { $0.isASCII && $0.isNumber } }),
            let year = Int(parts[0]), let month = Int(parts[1]), let day = Int(parts[2])
        else { return nil }
        self.init(year: year, month: month, day: day)
        // A day that rolls over into the next month ("2026-02-30") is not a day.
        guard let start = startOfDay(in: calendar), MVCalendarDay(start, calendar: calendar) == self else {
            return nil
        }
    }

    public var description: String {
        String(format: "%04d-%02d-%02d", year, month, day)
    }

    public static func < (lhs: MVCalendarDay, rhs: MVCalendarDay) -> Bool {
        (lhs.year, lhs.month, lhs.day) < (rhs.year, rhs.month, rhs.day)
    }

    /// Local midnight at the start of this day; `nil` for a combination the calendar rejects.
    public func startOfDay(in calendar: Calendar) -> Date? {
        let gregorian = Self.gregorian(in: calendar)
        return gregorian.date(from: DateComponents(year: year, month: month, day: day))
    }

    private static func gregorian(in calendar: Calendar) -> Calendar {
        var gregorian = Calendar(identifier: .gregorian)
        gregorian.timeZone = calendar.timeZone
        return gregorian
    }
}

/// The time window a search is narrowed to. A preset is kept as the preset and resolved against
/// "now" every time a query runs, so "Last 7 days" stays rolling; the slider and the custom range
/// keep whole local days. Resolves to the `received_after` / `received_before` bounds both search
/// endpoints take.
public enum MVTimeWindow: Hashable, Codable, Sendable {
    public enum Preset: String, Hashable, Codable, Sendable, CaseIterable {
        case today, sinceYesterday, last7Days, last30Days

        public var title: String {
            switch self {
            case .today: return "Today"
            case .sinceYesterday: return "Since yesterday"
            case .last7Days: return "Last 7 days"
            case .last30Days: return "Last 30 days"
            }
        }
    }

    case preset(Preset)
    /// A slider selection; `until == nil` runs to the moment of the query.
    case slider(since: MVCalendarDay, until: MVCalendarDay?)
    /// Both days inclusive.
    case custom(since: MVCalendarDay, until: MVCalendarDay)

    /// The slider's axis is the last 52 weeks at week granularity: stop `p` is local midnight today
    /// minus `(52 - p)` weeks.
    public static let sliderStops = 52

    /// Local midnight of the slider stop `stop`.
    public static func sliderDate(stop: Int, now: Date, calendar: Calendar = .current) -> Date {
        let today = calendar.startOfDay(for: now)
        return calendar.date(byAdding: .day, value: -(sliderStops - stop) * 7, to: today) ?? today
    }

    /// The window a slider selection `[start, end]` stands for; the thumbs stay on the axis with at
    /// least one stop between them, and the last stop means "until now".
    public static func slider(
        startStop: Int, endStop: Int, now: Date, calendar: Calendar = .current
    ) -> MVTimeWindow {
        let lower = min(max(startStop, 0), sliderStops - 1)
        let upper = min(max(endStop, lower + 1), sliderStops)
        return .slider(
            since: MVCalendarDay(sliderDate(stop: lower, now: now, calendar: calendar), calendar: calendar),
            until: upper == sliderStops
                ? nil : MVCalendarDay(sliderDate(stop: upper, now: now, calendar: calendar), calendar: calendar)
        )
    }

    /// The stops the slider shows for this window: its own for a slider window, the full axis for
    /// anything else, so opening the slider with nothing chosen means "the last 52 weeks".
    public func sliderSelection(now: Date, calendar: Calendar = .current) -> ClosedRange<Int> {
        guard case .slider(let since, let until) = self else { return 0...Self.sliderStops }
        let today = MVCalendarDay(now, calendar: calendar)
        let lower = min(max(Self.stop(of: since, today: today, calendar: calendar), 0), Self.sliderStops - 1)
        let upper = until.map { Self.stop(of: $0, today: today, calendar: calendar) } ?? Self.sliderStops
        return lower...min(max(upper, lower + 1), Self.sliderStops)
    }

    /// The axis stop nearest to `day`, counted in whole weeks back from `today`.
    private static func stop(of day: MVCalendarDay, today: MVCalendarDay, calendar: Calendar) -> Int {
        guard let dayStart = day.startOfDay(in: calendar), let todayStart = today.startOfDay(in: calendar) else {
            return 0
        }
        let days = calendar.dateComponents([.day], from: dayStart, to: todayStart).day ?? 0
        return sliderStops - Int((Double(days) / 7).rounded())
    }

    public var isSlider: Bool {
        if case .slider = self { return true }
        return false
    }

    /// A month label on the slider's axis, at the first stop of that month. `year` is set on the
    /// first label and on every January, the places the axis needs a year for orientation.
    public struct MonthMark: Hashable, Sendable {
        public let stop: Int
        public let label: String
        public let year: Int?
    }

    /// The stop in each month's first week, for the labels along the axis.
    public static func monthMarks(now: Date, calendar: Calendar = .current) -> [MonthMark] {
        let names = [
            "Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec",
        ]
        var marks: [MonthMark] = []
        for stop in 0...sliderStops {
            let day = MVCalendarDay(sliderDate(stop: stop, now: now, calendar: calendar), calendar: calendar)
            guard day.day <= 7 else { continue }
            marks.append(
                MonthMark(
                    stop: stop, label: names[day.month - 1],
                    year: marks.isEmpty || day.month == 1 ? day.year : nil))
        }
        return marks
    }

    /// The bounds to send for this window at `now`; `until` is `now` for every open-ended window.
    public func bounds(now: Date, calendar: Calendar = .current) -> (since: Date, until: Date) {
        switch self {
        case .preset(.today):
            return (calendar.startOfDay(for: now), now)
        case .preset(.sinceYesterday):
            let today = calendar.startOfDay(for: now)
            return (calendar.date(byAdding: .day, value: -1, to: today) ?? today, now)
        case .preset(.last7Days):
            return (now.addingTimeInterval(-7 * 24 * 3600), now)
        case .preset(.last30Days):
            return (now.addingTimeInterval(-30 * 24 * 3600), now)
        case .slider(let since, let until):
            return Self.bounds(since: since, until: until, now: now, calendar: calendar)
        case .custom(let since, let until):
            return Self.bounds(since: since, until: until, now: now, calendar: calendar)
        }
    }

    private static func bounds(
        since: MVCalendarDay, until: MVCalendarDay?, now: Date, calendar: Calendar
    ) -> (since: Date, until: Date) {
        let start = since.startOfDay(in: calendar) ?? calendar.startOfDay(for: now)
        guard let until, let untilStart = until.startOfDay(in: calendar) else { return (start, now) }
        return (start, endOfDay(untilStart, calendar: calendar))
    }

    /// The last instant of the day `date` falls on.
    private static func endOfDay(_ date: Date, calendar: Calendar) -> Date {
        let start = calendar.startOfDay(for: date)
        let next = calendar.date(byAdding: .day, value: 1, to: start) ?? start.addingTimeInterval(86_400)
        return next.addingTimeInterval(-0.001)
    }

    /// The preset's name, `YYYY-MM-DD – YYYY-MM-DD`, or `YYYY-MM-DD – now`.
    public var label: String {
        switch self {
        case .preset(let preset): return preset.title
        case .slider(let since, let until): return "\(since) – \(until.map(\.description) ?? "now")"
        case .custom(let since, let until): return "\(since) – \(until)"
        }
    }
}
