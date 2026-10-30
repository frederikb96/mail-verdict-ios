import Foundation

/// `YYYY-MM-DD` day strings, the form the server sends event and timeline dates in. Compared as
/// text (the form sorts the same as the dates it names) and turned into a `Date` only to display.
public enum MVOrderDay {
    /// The calendar day `date` falls on in `calendar`.
    public static func string(for date: Date, calendar: Calendar = .current) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }

    /// Noon of the named day in `calendar`, or `nil` for text that is not a day.
    public static func date(from day: String, calendar: Calendar = .current) -> Date? {
        let pieces = day.split(separator: "-").compactMap { Int($0) }
        guard pieces.count == 3 else { return nil }
        return calendar.date(from: DateComponents(year: pieces[0], month: pieces[1], day: pieces[2], hour: 12))
    }
}

extension OrderListItem {
    /// The day this entry sits on in the timeline.
    public var timelineDay: String? { timelineDate ?? eventStart }
}

/// One row of the ticket timeline.
public enum OrderTimelineEntry: Identifiable, Sendable, Equatable {
    case today
    case order(OrderListItem)

    public var id: String {
        switch self {
        case .today: return OrderTimeline.todayID
        case .order(let item): return item.id.uuidString
        }
    }
}

/// Tickets by the day they are for, newest day first, with a "today" marker between what is still
/// ahead and what has passed: future at the top, past below, today's own tickets just under the
/// marker.
public struct OrderTimeline: Sendable, Equatable {
    public static let todayID = "timeline-today"

    public let entries: [OrderTimelineEntry]
    /// Where the marker sits in `entries`.
    public let todayIndex: Int
    /// How many entries are still ahead of today.
    public var upcomingCount: Int { todayIndex }

    /// An entry with no day sorts below everything dated. Entries on the same day keep the order
    /// they came in, which is the server's.
    public static func build(items: [OrderListItem], today: String) -> OrderTimeline {
        let ordered = items.enumerated().sorted { lhs, rhs in
            switch (lhs.element.timelineDay, rhs.element.timelineDay) {
            case (let a?, let b?): return a != b ? a > b : lhs.offset < rhs.offset
            case (nil, nil): return lhs.offset < rhs.offset
            case (_?, nil): return true
            case (nil, _?): return false
            }
        }.map(\.element)
        let ahead = ordered.prefix { ($0.timelineDay ?? "") > today }
        var entries = ahead.map(OrderTimelineEntry.order)
        let index = entries.count
        entries.append(.today)
        entries += ordered.dropFirst(ahead.count).map(OrderTimelineEntry.order)
        return OrderTimeline(entries: entries, todayIndex: index)
    }
}
