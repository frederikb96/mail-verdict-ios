import Foundation

/// The things a person can do to an order -- the one list the detail's Options menu, a list row's
/// long-press menu and both swipes read, so the three entry points cannot drift apart. Wording
/// mirrors the web's order actions.
public enum OrderAction: String, CaseIterable, Sendable, Equatable {
    case favorite, close, seal, rewrite, delete
}

/// The flags an action's wording and request depend on.
public struct OrderFlags: Sendable, Equatable {
    public let isFavorite: Bool
    public let isOpen: Bool
    public let isSealed: Bool

    public init(isFavorite: Bool, isOpen: Bool, isSealed: Bool) {
        self.isFavorite = isFavorite
        self.isOpen = isOpen
        self.isSealed = isSealed
    }
}

extension OrderListItem {
    public var flags: OrderFlags { OrderFlags(isFavorite: isFavorite, isOpen: isOpen, isSealed: isSealed) }
}

extension OrderDetail {
    public var flags: OrderFlags { OrderFlags(isFavorite: isFavorite, isOpen: isOpen, isSealed: isSealed) }
}

public struct OrderActionEntry: Sendable, Equatable, Identifiable {
    public let action: OrderAction
    public let title: String
    /// A muted second line under the title.
    public let hint: String?
    public let systemImage: String
    public let isDestructive: Bool
    /// A divider belongs above this entry.
    public let separatorBefore: Bool

    public var id: OrderAction { action }
}

public enum OrderActionSet {

    public static func entries(for flags: OrderFlags) -> [OrderActionEntry] {
        [
            OrderActionEntry(
                action: .favorite, title: title(.favorite, flags), hint: nil,
                systemImage: flags.isFavorite ? MVSymbols.starFilled : MVSymbols.star,
                isDestructive: false, separatorBefore: false),
            OrderActionEntry(
                action: .close, title: title(.close, flags), hint: nil,
                systemImage: flags.isOpen ? "checkmark.circle" : "arrow.uturn.backward.circle",
                isDestructive: false, separatorBefore: false),
            OrderActionEntry(
                action: .seal, title: title(.seal, flags),
                hint: flags.isSealed ? "Mail is added again" : "Add no more mail",
                systemImage: flags.isSealed ? "lock.open" : "lock",
                isDestructive: false, separatorBefore: false),
            OrderActionEntry(
                action: .rewrite, title: title(.rewrite, flags), hint: nil,
                systemImage: "arrow.triangle.2.circlepath", isDestructive: false, separatorBefore: true),
            OrderActionEntry(
                action: .delete, title: title(.delete, flags), hint: nil, systemImage: "trash",
                isDestructive: true, separatorBefore: true),
        ]
    }

    /// The wording for one action in its current state -- also what a swipe button reads.
    public static func title(_ action: OrderAction, _ flags: OrderFlags) -> String {
        switch action {
        case .favorite: return flags.isFavorite ? "Unfavorite" : "Favorite"
        case .close: return flags.isOpen ? "Close" : "Reopen"
        case .seal: return flags.isSealed ? "Unseal" : "Seal"
        case .rewrite: return "Rewrite Summary"
        case .delete: return "Delete Order…"
        }
    }

    /// The request a flag-flipping action amounts to plus the toast text once it lands; `nil` for
    /// rewrite and delete, which are not a flag flip. Closing sends `isOpen: false`, so the server
    /// records the decision as a person's.
    public static func toggle(_ action: OrderAction, _ flags: OrderFlags) -> (
        update: OrderUpdateRequest, message: String
    )? {
        switch action {
        case .favorite:
            return flags.isFavorite
                ? (OrderUpdateRequest(isFavorite: false), "Removed from favorites")
                : (OrderUpdateRequest(isFavorite: true), "Added to favorites")
        case .close:
            return flags.isOpen
                ? (OrderUpdateRequest(isOpen: false), "Order closed")
                : (OrderUpdateRequest(isOpen: true), "Order reopened")
        case .seal:
            return flags.isSealed
                ? (OrderUpdateRequest(isSealed: false), "Order unsealed")
                : (OrderUpdateRequest(isSealed: true), "Order sealed")
        case .rewrite, .delete:
            return nil
        }
    }
}
