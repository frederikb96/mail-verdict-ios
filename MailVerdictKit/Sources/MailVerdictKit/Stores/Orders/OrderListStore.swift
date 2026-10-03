import Foundation
import Observation

/// Every order and ticket bundle across every enabled account, newest activity first.
@Observable
@MainActor
public final class OrderListStore {
    public enum Filter: String, CaseIterable, Sendable, Identifiable {
        case all, open, favorites

        public var id: String { rawValue }
        public var label: String {
            switch self {
            case .all: return "All"
            case .open: return "Open"
            case .favorites: return "Favorites"
            }
        }

        /// What the server's `state` parameter gets -- Favorites is `all` plus `favorites=true`.
        var state: String { self == .open ? "open" : "all" }
        var favoritesOnly: Bool { self == .favorites }
    }

    public private(set) var rows: [OrderListItem] = []
    /// Orders new to the list since the reader last settled at the top -- held back rather than
    /// inserted, so nothing shifts under a reader scrolled into the list. See `MVStableOrder`.
    public private(set) var held: [OrderListItem] = []
    public private(set) var isLoading = false
    public private(set) var isLoadingMore = false
    public private(set) var errorMessage: String?
    public private(set) var hasMore = false
    public private(set) var filter: Filter
    /// The text the server filters by (merchant, subject, status, summary), already debounced.
    public private(set) var query = ""
    private var nextCursor: String?
    /// The server's own current order, kept up to date by every fetch regardless of `rows`/`held`
    /// -- what `takeOverHeld()` adopts wholesale, the same role `itemsRef` plays for the web's own
    /// `takeOverFresh`.
    private var latestFresh: [OrderListItem] = []

    /// The screen's own "is the first row visible" signal -- read only when a live invalidation
    /// arrives (`apply(_:)`), never written by this store. Defaults to `true`: an empty or
    /// still-loading list has nothing to preserve a scroll position within.
    public var isAtTop = true

    private let apiClient: MVApiClient
    private let queryDebounce: Duration
    private var liveSubscriptionToken: MVSubscriptionToken?
    private var pendingQuery: Task<Void, Never>?

    public init(apiClient: MVApiClient, filter: Filter = .all, queryDebounce: Duration = .milliseconds(150)) {
        self.apiClient = apiClient
        self.filter = filter
        self.queryDebounce = queryDebounce
    }

    /// Takes what the filter field shows; the list reloads once typing pauses, the same 150 ms the
    /// mail quick filter waits. A reload for a superseded value never lands.
    public func setQuery(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        pendingQuery?.cancel()
        guard trimmed != query else { return }
        pendingQuery = Task { [weak self, queryDebounce] in
            try? await Task.sleep(for: queryDebounce)
            guard !Task.isCancelled, let self else { return }
            self.query = trimmed
            await self.load()
        }
    }

    public func setFilter(_ filter: Filter) async {
        guard filter != self.filter else { return }
        self.filter = filter
        await load()
    }

    public func load() async {
        isLoading = rows.isEmpty
        errorMessage = nil
        held = []
        do {
            let response = try await apiClient.listOrders(
                state: filter.state, favorites: filter.favoritesOnly, query: query, limit: 50)
            rows = response.items
            latestFresh = response.items
            hasMore = response.hasMore
            nextCursor = response.nextCursor
        } catch {
            errorMessage = error.mvUserMessage
        }
        isLoading = false
    }

    public func loadMore() async {
        guard hasMore, !isLoadingMore else { return }
        isLoadingMore = true
        if let response = try? await apiClient.listOrders(
            state: filter.state, favorites: filter.favoritesOnly, query: query,
            before: nextCursor.flatMap(UUID.init(uuidString:)), limit: 50
        ) {
            rows.append(contentsOf: response.items)
            hasMore = response.hasMore
            nextCursor = response.nextCursor
        }
        isLoadingMore = false
    }

    /// Runs one of the order actions on a list row and returns the toast text for it, or `nil`
    /// when the action has no confirmation of its own (rewrite). A flag flip replaces the row in
    /// place with what the server reports; delete removes it.
    @discardableResult
    public func perform(_ action: OrderAction, on item: OrderListItem) async throws -> String? {
        if let toggle = OrderActionSet.toggle(action, item.flags) {
            let detail = try await apiClient.updateOrder(id: item.id, toggle.update)
            replace(detail.listItem)
            return toggle.message
        }
        switch action {
        case .rewrite:
            try await apiClient.rewriteOrder(id: item.id)
            return "Rewriting the summary…"
        case .delete:
            try await apiClient.deleteOrder(id: item.id)
            rows.removeAll { $0.id == item.id }
            latestFresh.removeAll { $0.id == item.id }
            held.removeAll { $0.id == item.id }
            return "Order deleted"
        case .favorite, .close, .seal:
            return nil
        }
    }

    private func replace(_ item: OrderListItem) {
        if let index = rows.firstIndex(where: { $0.id == item.id }) { rows[index] = item }
        if let index = latestFresh.firstIndex(where: { $0.id == item.id }) { latestFresh[index] = item }
        if let index = held.firstIndex(where: { $0.id == item.id }) { held[index] = item }
    }

    /// "New activity" tapped, or the reader scrolled back to the very top -- a local swap, no
    /// network round trip: `latestFresh` is already the server's own current order, kept current
    /// by every `refreshInPlace` regardless of whether it was shown yet.
    public func takeOverHeld() {
        let result = MVStableOrder.takeOver(fresh: latestFresh)
        rows = result.rows
        held = result.held
    }

    /// Re-fetches the whole loaded window and applies `MVStableOrder` -- `atTop` decides whether
    /// this lands as an immediate reorder (nothing held) or preserves positions and queues new
    /// rows behind the "New activity" pill.
    private func refreshInPlace(atTop: Bool) async {
        guard
            let response = try? await apiClient.listOrders(
                state: filter.state, favorites: filter.favoritesOnly, query: query, limit: max(rows.count, 50))
        else { return }
        let result = MVStableOrder.apply(shown: rows, fresh: response.items, atTop: atTop)
        rows = result.rows
        held = result.held
        latestFresh = response.items
        hasMore = response.hasMore
        nextCursor = response.nextCursor
    }
}

extension OrderListStore {
    public func subscribeToLive(_ hub: LiveEventHub) {
        guard liveSubscriptionToken == nil else { return }
        liveSubscriptionToken = hub.subscribe(self)
    }

    public func unsubscribeFromLive(_ hub: LiveEventHub) {
        guard let token = liveSubscriptionToken else { return }
        hub.unsubscribe(token)
        liveSubscriptionToken = nil
    }
}

extension OrderListStore: LiveEventSubscriber {
    public func apply(_ invalidations: [MVLiveInvalidation]) {
        let shouldReload = invalidations.contains {
            switch $0 {
            case .resync, .orderChanged: return true
            default: return false
            }
        }
        guard shouldReload else { return }
        let atTop = isAtTop
        Task { await self.refreshInPlace(atTop: atTop) }
    }
}
