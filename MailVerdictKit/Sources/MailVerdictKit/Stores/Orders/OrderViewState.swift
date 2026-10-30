import Foundation

/// The kind control of the orders list: everything, goods, or tickets (which opens as a timeline).
public enum OrderKindFilter: String, Codable, Sendable, Equatable, CaseIterable, Identifiable {
    case all, orders, tickets

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .all: return "All"
        case .orders: return "Orders"
        case .tickets: return "Tickets"
        }
    }

    /// The server's `kind` parameter.
    var apiKind: String {
        switch self {
        case .all: return "all"
        case .orders: return "order"
        case .tickets: return "ticket"
        }
    }
}

/// What the orders list shows: one kind, optionally only open entries and only favorites. The
/// three combine (Open + Tickets is the upcoming tickets) and survive a relaunch.
public struct OrderViewState: Codable, Sendable, Equatable {
    public var kind: OrderKindFilter
    public var open: Bool
    public var favorites: Bool

    public init(kind: OrderKindFilter = .all, open: Bool = false, favorites: Bool = false) {
        self.kind = kind
        self.open = open
        self.favorites = favorites
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        kind = (try? container.decode(OrderKindFilter.self, forKey: .kind)) ?? .all
        open = (try? container.decode(Bool.self, forKey: .open)) ?? false
        favorites = (try? container.decode(Bool.self, forKey: .favorites)) ?? false
    }

    /// Tickets are read as a timeline, ordered by the day they are for rather than by activity.
    public var isTimeline: Bool { kind == .tickets }

    var state: String { open ? "open" : "all" }
    var sort: String { isTimeline ? "event" : "activity" }

    /// Names which list this is: a change of it is a new list, which starts at its own start
    /// (the top, or today on the timeline) instead of keeping the old offset.
    public var identity: String { "\(kind.rawValue)-\(open ? "open" : "any")-\(favorites ? "fav" : "any")" }
}

/// The view state in `UserDefaults`; a missing or unreadable value is the default view.
// `@unchecked Sendable`: see `SearchPersistence` -- `UserDefaults` is thread-safe by Apple's
// documentation, swift-corelibs-foundation just does not say so.
public struct OrderViewPersistence: @unchecked Sendable {
    private static let key = "mv.orders.view"

    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public func load() -> OrderViewState {
        guard let data = defaults.data(forKey: Self.key),
            let state = try? JSONDecoder().decode(OrderViewState.self, from: data)
        else { return OrderViewState() }
        return state
    }

    public func save(_ state: OrderViewState) {
        guard let data = try? JSONEncoder().encode(state) else { return }
        defaults.set(data, forKey: Self.key)
    }
}
