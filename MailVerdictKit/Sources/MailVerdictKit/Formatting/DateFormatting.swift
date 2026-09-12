import Foundation

/// Day-first, 24-hour, English month/weekday names regardless of the device's own locale — the
/// one date/time convention every timestamp in the app uses, porting `ui/src/lib/format.ts`'s
/// identical rule (an English-locale `date-fns` call ignores the browser's locale too).
public enum MVDateFormat {

    // `DateFormatter` is not `Sendable`, but every instance here is built once, configured, and
    // only ever read from afterward.
    nonisolated(unsafe) private static let timeFormatter = makeFormatter("HH:mm")
    nonisolated(unsafe) private static let weekdayFormatter = makeFormatter("EEE")
    nonisolated(unsafe) private static let dayMonthFormatter = makeFormatter("d MMM")
    nonisolated(unsafe) private static let dayMonthYearFormatter = makeFormatter("d MMM yyyy")
    nonisolated(unsafe) private static let fullFormatter = makeFormatter("EEE, d MMM yyyy, HH:mm")

    private static func makeFormatter(_ format: String) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = format
        return formatter
    }

    /// A list row's timestamp: the time for anything received today, the weekday name for the
    /// six days before that, and a day-first date beyond it — with the year appended only once
    /// it is not the current one. Never a relative duration ("2h", "3d"): those drift as the
    /// clock moves on without the row re-rendering. A date after today (spam routinely dates
    /// itself ahead to sit at the top of a list) is always the plain date, never a bare weekday
    /// that would pass for one in the past week.
    public static func relativeDate(_ date: Date?, now: Date = Date(), calendar: Calendar = .current) -> String {
        guard let date else { return "" }
        // `Calendar.isDateInToday`/`isDateInYesterday` compare against the real wall-clock date,
        // never an injected `now` — exactly the one thing a test needs to control, so "today" and
        // "yesterday" are derived from `now` by hand instead.
        let daysAgo =
            calendar.dateComponents(
                [.day], from: calendar.startOfDay(for: date), to: calendar.startOfDay(for: now)
            ).day ?? 0
        if daysAgo == 0 { return timeFormatter.string(from: date) }
        if daysAgo == 1 { return "Yesterday" }
        if daysAgo > 0, daysAgo < 7 {
            return weekdayFormatter.string(from: date)
        }

        let sameYear = calendar.component(.year, from: date) == calendar.component(.year, from: now)
        return (sameYear ? dayMonthFormatter : dayMonthYearFormatter).string(from: date)
    }

    /// `relativeDate` plus a trailing "ago" a sentence like "Synced … ago" needs — only for
    /// something within the last hour, the one case `relativeDate` reads as a bare clock time
    /// that would otherwise make no sense mid-sentence ("Synced 14:32").
    public static func relativeAgo(_ date: Date?, now: Date = Date(), calendar: Calendar = .current) -> String {
        guard let date else { return "" }
        let minutesAgo = calendar.dateComponents([.minute], from: date, to: now).minute ?? 0
        if minutesAgo < 1 { return "just now" }
        if minutesAgo < 60 { return "\(minutesAgo)m ago" }
        return relativeDate(date, now: now, calendar: calendar)
    }

    /// The full date/time shown in the reading pane and thread header.
    public static func fullDate(_ date: Date?) -> String {
        guard let date else { return "" }
        return fullFormatter.string(from: date)
    }
}

/// Human-readable file size.
public func formatSize(_ bytes: Int?) -> String {
    guard let bytes, bytes > 0 else { return "0 B" }
    let units = ["B", "KB", "MB", "GB"]
    let exponent = min(Int(log(Double(bytes)) / log(1024)), units.count - 1)
    let value = Double(bytes) / pow(1024, Double(exponent))
    return String(format: exponent > 0 ? "%.1f %@" : "%.0f %@", value, units[exponent])
}
