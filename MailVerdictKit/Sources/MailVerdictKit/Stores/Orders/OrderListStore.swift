import Foundation
import Observation

/// Every order and ticket bundle across every enabled account. Tickets are a timeline by the day
/// they are for; everything else is newest activity first.
@Observable
@MainActor
public final class OrderListStore {
    public private(set) var rows: [OrderListItem] = []
    /// Orders new to the list since the reader last settled at the top -- held back rather than
    /// inserted, so nothing shifts under a reader scrolled into the list. See `MVStableOrder`.
    public private(set) var held: [OrderListItem] = []
    public private(set) var isLoading = false
    public private(set) var isLoadingMore = false
    public private(set) var errorMessage: String?
    public private(set) var hasMore = false
    public private(set) var view: OrderViewState
    /// The text the server filters by (merchant, subject, status, summary), already debounced.
    public private(set) var query = ""
    /// When the rows on screen were saved, if they came from the offline copy rather than the server.
    public private(set) var savedCopyAt: Date?
    private var nextCursor: String?
    /// The server's own current order, kept up to date by every fetch regardless of `rows`/`held`
    /// -- what `takeOverHeld()` adopts wholesale, the same role `itemsRef` plays for the web's own
    /// `takeOverFresh`.
    private var latestFresh: [OrderListItem] = []
    /// Bumped by every load and every view change, so an answer for a list that is no longer the
    /// one on screen never lands.
    private var generation = 0

    /// The screen's own "is the first row visible" signal -- read only when a live invalidation
    /// arrives (`apply(_:)`), never written by this store. Defaults to `true`: an empty or
    /// still-loading list has nothing to preserve a scroll position within.
    public var isAtTop = true

    private let apiClient: MVApiClient
    private let persistence: OrderViewPersistence?
    private let offlineCache: MVOfflineCache?
    private let today: @Sendable () -> String
    private let queryDebounce: Duration
    private var liveSubscriptionToken: MVSubscriptionToken?
    private var pendingQuery: Task<Void, Never>?
    private var prefetch: Task<Void, Never>?

    /// `view` overrides what `persistence` last saved. The timeline comes up to 500 tickets in one
    /// page: they are few, and a page boundary inside it would put a seam in the middle of a read.
    public init(
        apiClient: MVApiClient, view: OrderViewState? = nil, persistence: OrderViewPersistence? = nil,
        offlineCache: MVOfflineCache? = nil, queryDebounce: Duration = .milliseconds(150),
        today: @escaping @Sendable () -> String = { MVOrderDay.string(for: Date()) }
    ) {
        self.apiClient = apiClient
        self.view = view ?? persistence?.load() ?? OrderViewState()
        self.persistence = persistence
        self.offlineCache = offlineCache
        self.queryDebounce = queryDebounce
        self.today = today
    }

    /// The tickets as a timeline around today; meaningful while `view.isTimeline`.
    public var timeline: OrderTimeline { OrderTimeline.build(items: rows, today: today()) }

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
            self.startNewList()
            await self.load()
        }
    }

    /// A different view is a different list: its rows start empty and it begins at its own start.
    public func setView(_ new: OrderViewState) async {
        guard new != view else { return }
        view = new
        persistence?.save(new)
        startNewList()
        await load()
    }

    public func setKind(_ kind: OrderKindFilter) async {
        var next = view
        next.kind = kind
        await setView(next)
    }

    public func toggleOpen() async {
        var next = view
        next.open.toggle()
        await setView(next)
    }

    public func toggleFavorites() async {
        var next = view
        next.favorites.toggle()
        await setView(next)
    }

    private func startNewList() {
        generation += 1
        rows = []
        held = []
        latestFresh = []
        hasMore = false
        nextCursor = nil
        savedCopyAt = nil
        errorMessage = nil
    }

    private var pageLimit: Int { view.isTimeline ? 500 : 50 }

    private func fetch(before: UUID? = nil, limit: Int, view requested: OrderViewState) async throws
        -> OrderListResponse
    {
        try await apiClient.listOrders(
            state: requested.state, favorites: requested.favorites, kind: requested.kind.apiKind,
            sort: requested.sort, query: query, before: before, limit: limit)
    }

    public func load() async {
        generation += 1
        let mine = generation
        let requested = view
        isLoading = rows.isEmpty
        errorMessage = nil
        held = []
        do {
            let response = try await fetch(limit: pageLimit, view: requested)
            guard mine == generation else { return }
            rows = response.items
            latestFresh = response.items
            hasMore = response.hasMore
            nextCursor = response.nextCursor
            savedCopyAt = nil
            keepCopy(of: response, for: requested)
        } catch {
            guard mine == generation, !error.mvIsCancellation else { return }
            if error.mvIsServerUnreachable, await showSavedList(for: requested, generation: mine) {
                // Offline: the saved list stands in until the server answers again.
            } else if mine == generation {
                errorMessage = error.mvUserMessage
            }
        }
        if mine == generation { isLoading = false }
    }

    private func showSavedList(for requested: OrderViewState, generation mine: Int) async -> Bool {
        guard query.isEmpty, let offlineCache, let saved = await offlineCache.orderList(key: requested.identity),
            mine == generation
        else { return false }
        rows = saved.items
        latestFresh = saved.items
        hasMore = false
        nextCursor = nil
        savedCopyAt = saved.savedAt
        return true
    }

    /// Saves the first page of an unfiltered view and gets the tickets coming up ready to show
    /// without reception.
    private func keepCopy(of response: OrderListResponse, for requested: OrderViewState) {
        guard let offlineCache, query.isEmpty else { return }
        let key = requested.identity
        let api = apiClient
        let day = today()
        prefetch?.cancel()
        prefetch = Task {
            await offlineCache.saveOrderList(response.items, hasMore: response.hasMore, key: key)
            await OrderOfflineCopy.prepare(response.items, today: day, api: api, cache: offlineCache)
        }
    }

    public func loadMore() async {
        guard hasMore, !isLoadingMore else { return }
        isLoadingMore = true
        let mine = generation
        let requested = view
        if let response = try? await fetch(
            before: nextCursor.flatMap(UUID.init(uuidString:)), limit: pageLimit, view: requested),
            mine == generation
        {
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
    /// rows behind the "New activity" pill. The timeline has no pill: its rows are ordered by the
    /// day they are for, so an arrival lands where its day is and the list keeps its anchor.
    private func refreshInPlace(atTop: Bool) async {
        let mine = generation
        let requested = view
        guard let response = try? await fetch(limit: max(rows.count, pageLimit), view: requested),
            mine == generation
        else { return }
        if requested.isTimeline {
            rows = response.items
            held = []
        } else {
            let result = MVStableOrder.apply(shown: rows, fresh: response.items, atTop: atTop)
            rows = result.rows
            held = result.held
        }
        latestFresh = response.items
        hasMore = response.hasMore
        nextCursor = response.nextCursor
        savedCopyAt = nil
        keepCopy(of: response, for: requested)
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
