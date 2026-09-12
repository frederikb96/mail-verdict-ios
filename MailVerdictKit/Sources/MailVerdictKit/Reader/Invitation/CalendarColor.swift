import Foundation

/// The colour a calendar renders with — port of `resolveCalendarColor` in the web's
/// `components/calendar/colors.ts`: a user override wins, then the server's own colour, then a
/// palette colour derived from the calendar's id so an uncoloured calendar keeps a stable colour.
public enum CalendarColor {

    /// `CALENDAR_PALETTE` in `colors.ts`.
    static let palette = [
        "#3b82f6", "#22c55e", "#f97316", "#a855f7", "#ec4899", "#14b8a6",
        "#eab308", "#ef4444", "#6366f1", "#84cc16", "#06b6d4", "#f43f5e",
    ]

    /// Only a hex colour reaches the page's markup — the value comes from a CalDAV server and
    /// lands inside a `style` attribute.
    private static let hexColorPattern = #"^#(?:[0-9a-fA-F]{3,4}|[0-9a-fA-F]{6}|[0-9a-fA-F]{8})$"#

    public static func resolve(_ calendar: MVCalendar) -> String {
        for candidate in [calendar.colorOverride, calendar.color] {
            if let candidate, candidate.range(of: hexColorPattern, options: .regularExpression) != nil {
                return candidate
            }
        }
        return paletteColor(forCalendarId: calendar.id)
    }

    /// `paletteColorForCalendarId`: djb2 over the id as the API serves it (lower-case), wrapped
    /// to 32 bits exactly as the web's `| 0` does, so both clients pick the same colour.
    static func paletteColor(forCalendarId id: UUID) -> String {
        var hash: Int32 = 5381
        for unit in id.uuidString.lowercased().utf16 {
            hash = hash &* 33 &+ Int32(unit)
        }
        return palette[Int(abs(Int64(hash)) % Int64(palette.count))]
    }
}
