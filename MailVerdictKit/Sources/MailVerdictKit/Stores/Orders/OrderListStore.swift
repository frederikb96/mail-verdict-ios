import Foundation
import Observation

/// Every order and ticket bundle across every enabled account, newest activity first.
@Observable
@MainActor
public final class OrderListStore {
    public enum Filter: String, CaseIterable, Sendable, Identifiable {
        case all, open

        public var id: String { rawValue }
        public var label: String { self == .all ? "All" : "Open" }
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
    private var nextCursor: String?

    /// The screen's own "is the first row visible" signal -- read only when a live invalidation
    /// arrives (`apply(_:)`), never written by this store. Defaults to `true`: an empty or
    /// still-loading list has nothing to preserve a scroll position within.
    public var isAtTop = true

    private let apiClient: MVApiClient
    private var liveSubscriptionToken: MVSubscriptionToken?

    public init(apiClient: MVApiClient, filter: Filter = .all) {
        self.apiClient = apiClient
        self.filter = filter
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
            let response = try await apiClient.listOrders(state: filter.rawValue, limit: 50)
            rows = response.items
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
            state: filter.rawValue, before: nextCursor.flatMap(UUID.init(uuidString:)), limit: 50
        ) {
            rows.append(contentsOf: response.items)
            hasMore = response.hasMore
            nextCursor = response.nextCursor
        }
        isLoadingMore = false
    }

    /// "New activity" tapped, or the reader scrolled back to the very top -- a local merge, no
    /// network round trip: `held` is already in the server's own order, so it is simply what goes
    /// first.
    public func takeOverHeld() {
        let result = MVStableOrder.takeOver(rows: rows, held: held)
        rows = result.rows
        held = result.held
    }

    /// Re-fetches the whole loaded window and applies `MVStableOrder` -- `atTop` decides whether
    /// this lands as an immediate reorder (nothing held) or preserves positions and queues new
    /// rows behind the "New activity" pill.
    private func refreshInPlace(atTop: Bool) async {
        guard
            let response = try? await apiClient.listOrders(state: filter.rawValue, limit: max(rows.count, 50))
        else { return }
        let result = MVStableOrder.apply(shown: rows, fresh: response.items, atTop: atTop)
        rows = result.rows
        held = result.held
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
