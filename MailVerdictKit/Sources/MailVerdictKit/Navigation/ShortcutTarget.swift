import Foundation

/// Where an action from the Shortcuts app lands.
public enum MVShortcutTarget: Sendable, Equatable {
    case newMessage
    case orders(OrderViewState)
    case list(ListScope)
    case search

    /// The stack this target lands on, replacing the one on screen; `nil` when it opens over
    /// whatever is there.
    public var path: [Route]? {
        switch self {
        case .newMessage: return nil
        case .orders: return [.orders]
        case .list(let scope): return [.list(scope, aroundMessageId: nil)]
        case .search: return [.search(initialQuery: nil)]
        }
    }
}
