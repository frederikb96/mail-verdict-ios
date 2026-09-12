import Foundation
import Observation

/// Search — text and semantic modes, every filter the UX design's chip bar offers, results built
/// from the same `MVMailRowData` the list uses, persisted prefs and scroll position, and
/// `ReaderListSource` so the reader pages through results in result order.
@Observable
@MainActor
public final class SearchStore {
    public private(set) var context: SearchContext
    public private(set) var results: [SearchResult] = []
    public private(set) var isLoading = false
    public private(set) var isLoadingMore = false
    public private(set) var errorMessage: String?
    public private(set) var total: Int?
    public private(set) var hasSearched = false
    private(set) var hasMore = false
    private var nextCursor: String?

    public var resultsState: MVSearchResultsState {
        SearchSupport.resultsState(
            query: context.query, folderIds: context.folderIds, isLoading: isLoading, errorMessage: errorMessage,
            resultCount: results.count, hasSearched: hasSearched
        )
    }

    private let apiClient: MVApiClient
    private let persistence: SearchPersistence
    private var searchTask: Task<Outcome, Never>?
    private var debounceTask: Task<Void, Never>?
    private var generation = 0
    private var liveSubscriptionToken: MVSubscriptionToken?

    public init(
        apiClient: MVApiClient, persistence: SearchPersistence = SearchPersistence(), initialQuery: String? = nil
    ) {
        self.apiClient = apiClient
        self.persistence = persistence
        var restored = persistence.loadContext() ?? SearchContext(mode: .text, query: "")
        if let initialQuery, !initialQuery.isEmpty {
            restored = SearchContext(
                mode: restored.mode, query: initialQuery, accountId: restored.accountId,
                folderIds: restored.folderIds, fields: restored.fields, strictness: restored.strictness,
                sort: restored.sort, receivedAfter: restored.receivedAfter, receivedBefore: restored.receivedBefore
            )
        }
        self.context = restored
    }

    // MARK: - Scroll anchor

    public var topVisibleRowId: String? {
        get { persistence.loadAnchor(for: context) }
        set { persistence.saveAnchor(newValue, for: context) }
    }

    // MARK: - Updating scope — every setter but the query field re-runs the search immediately

    /// Called by every chip (mode, fields, strictness, sort, account, folders, dates) — none of
    /// them need debouncing, unlike free-text typing, so this awaits the search directly rather
    /// than firing a detached task a caller has no handle on.
    public func updateContext(_ newContext: SearchContext) async {
        guard newContext != context else { return }
        debounceTask?.cancel()
        context = newContext
        persistence.saveContext(newContext)
        await runSearch()
    }

    /// Debounced 150 ms, cancelling whatever was in flight — a fast typist's earlier keystrokes
    /// never race their own later ones for which result lands last.
    public func queryChanged(_ newQuery: String) {
        context = SearchContext(
            mode: context.mode, query: newQuery, accountId: context.accountId, folderIds: context.folderIds,
            fields: context.fields, strictness: context.strictness, sort: context.sort,
            receivedAfter: context.receivedAfter, receivedBefore: context.receivedBefore
        )
        persistence.saveContext(context)
        debounceTask?.cancel()
        debounceTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 150_000_000)
            guard !Task.isCancelled else { return }
            await self?.runSearch()
        }
    }

    // MARK: - Running the search

    public func runSearch() async {
        generation += 1
        let thisGeneration = generation
        searchTask?.cancel()

        // Both gates the UX design's own states list names — "search nothing" and "too short to
        // search" — checked here rather than only by `resultsState` (the screen's own rendering
        // decision), so an empty-folders or too-short query never reaches the network at all.
        guard context.folderIds?.isEmpty != true, context.query.count >= 2 else {
            results = []
            hasSearched = false
            errorMessage = nil
            total = nil
            return
        }

        isLoading = true
        errorMessage = nil
        let task = Task { [context] in
            await Self.performSearch(context: context, apiClient: apiClient)
        }
        searchTask = task
        let outcome = await task.value
        guard thisGeneration == generation else { return }

        switch outcome {
        case .success(let page):
            results = page.results
            hasMore = page.hasMore
            nextCursor = page.nextCursor
            total = page.total
        case .failure(let message):
            errorMessage = message
            results = []
            hasMore = false
            nextCursor = nil
            total = nil
        }
        isLoading = false
        hasSearched = true
        reportDebugState()
    }

    /// `/search/state`'s own data — reported here, on the main actor, rather than read directly
    /// from that route's synchronous, non-isolated handler.
    private func reportDebugState() {
        #if DEBUG
            SearchDebugReporter.shared.report(
                MVSearchDebugSnapshot(
                    mode: context.mode.rawValue, query: context.query, resultCount: results.count, total: total,
                    hasMore: hasMore, resultsState: "\(resultsState)"
                )
            )
        #endif
    }

    public func loadMore() async {
        guard hasMore, !isLoadingMore, context.mode == .text else { return }
        isLoadingMore = true
        let outcome = await Self.performSearch(context: context, apiClient: apiClient, before: nextCursor)
        if case .success(let page) = outcome {
            results.append(contentsOf: page.results)
            hasMore = page.hasMore
            nextCursor = page.nextCursor
        }
        isLoadingMore = false
    }

    private enum Outcome {
        case success(Page)
        case failure(String)
    }

    private struct Page {
        let results: [SearchResult]
        let hasMore: Bool
        let nextCursor: String?
        let total: Int?
    }

    /// `static`, capturing nothing but its arguments — a superseded search's result is discarded
    /// by `runSearch`'s generation check rather than by cancelling a half-built request.
    private static func performSearch(
        context: SearchContext, apiClient: MVApiClient, before: String? = nil
    ) async -> Outcome {
        do {
            switch context.mode {
            case .text:
                let sort: MVSearchSort = context.sort == .chronological ? .chronological : .relevance
                let response = try await apiClient.search(
                    query: context.query, accountId: context.accountId, folderIds: context.folderIds,
                    fields: context.fields, sort: sort, receivedAfter: context.receivedAfter,
                    receivedBefore: context.receivedBefore, before: before.flatMap(UUID.init(uuidString:))
                )
                return .success(
                    Page(
                        results: response.results, hasMore: response.hasMore, nextCursor: response.nextCursor,
                        total: response.total)
                )
            case .semantic:
                let sort: MVSemanticSort = context.sort == .chronological ? .chronological : .relevance
                let response = try await apiClient.semanticSearch(
                    query: context.query, accountId: context.accountId, folderIds: context.folderIds,
                    strictness: context.strictness, sort: sort, receivedAfter: context.receivedAfter,
                    receivedBefore: context.receivedBefore
                )
                return .success(
                    Page(results: response.results, hasMore: false, nextCursor: nil, total: response.results.count)
                )
            }
        } catch {
            let mvError = error as? MVError
            let statusCode: Int? = {
                switch mvError {
                case .detail(_, let code), .http(let code, _): return code
                default: return nil
                }
            }()
            let message = SearchSupport.errorMessage(
                mode: context.mode, statusCode: statusCode, serverDetail: mvError?.userMessage ?? "\(error)"
            )
            return .failure(message)
        }
    }
}

extension SearchStore: ReaderListSource {
    public var rowIds: [UUID] { results.map(\.id) }
    public var hasOlder: Bool { hasMore }
    public var hasNewer: Bool { false }

    public func neighbours(of messageId: UUID) -> (older: UUID?, newer: UUID?) {
        guard let index = results.firstIndex(where: { $0.id == messageId }) else { return (nil, nil) }
        let older = index + 1 < results.count ? results[index + 1].id : nil
        let newer = index > 0 ? results[index - 1].id : nil
        return (older, newer)
    }

    public func loadOlder() async { await loadMore() }
    public func loadNewer() async {}

    public var readerTitle: String? {
        guard let total else { return nil }
        return "\(total) Results"
    }
}

extension SearchStore {
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

extension SearchStore: LiveEventSubscriber {
    /// A mail change anywhere could move a result in or out of the current query's matches —
    /// re-running the same search (rather than trying to patch individual rows) is what the web
    /// itself does for any list on a mail event, and search has no cheaper option since results
    /// are server-ranked, not a simple filter over loaded rows.
    public func apply(_ invalidations: [MVLiveInvalidation]) {
        guard hasSearched else { return }
        let shouldReload = invalidations.contains {
            switch $0 {
            case .resync, .mailNew, .mailUpdated, .mailDeleted, .verdictIssued: return true
            default: return false
            }
        }
        guard shouldReload else { return }
        Task { await self.runSearch() }
    }
}
