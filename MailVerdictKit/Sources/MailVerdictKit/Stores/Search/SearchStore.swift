import Foundation
import Observation

/// Search — text and semantic modes, every filter the chip bar offers, results built from the
/// same `MVMailRowData` the list uses, persisted prefs and scroll position, and
/// `ReaderListSource` so the reader pages through results in result order.
@Observable
@MainActor
public final class SearchStore {
    public private(set) var context: SearchContext
    public private(set) var results: [MVSearchHit] = []
    public private(set) var isLoading = false
    public private(set) var isLoadingMore = false
    public private(set) var errorMessage: String?
    public private(set) var total: Int?
    public private(set) var hasSearched = false
    /// Where semantic mode stands: `pending` while the list on screen is the full-text one shown
    /// ahead of the meaning-based answer, `unavailable` once the server could not give one.
    public private(set) var semanticState = MVSemanticState.settled
    private(set) var hasMore = false
    private var nextCursor: String?

    public var resultsState: MVSearchResultsState {
        SearchSupport.resultsState(
            query: context.query, folderIds: context.folderIds, isLoading: isLoading, errorMessage: errorMessage,
            resultCount: results.count, hasSearched: hasSearched,
            semanticState: semanticState
        )
    }

    private let apiClient: MVApiClient
    private let persistence: SearchPersistence
    private var searchTask: Task<Outcome, Never>?
    private var fullTextTask: Task<Outcome, Never>?
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
            restored.query = initialQuery
        }
        self.context = restored
    }

    // MARK: - Scroll anchor

    public var topVisibleRowId: String? {
        get { persistence.loadAnchor(for: context) }
        set { persistence.saveAnchor(newValue, for: context) }
    }

    // MARK: - Updating scope — every setter but the query field re-runs the search immediately

    /// Called by every chip (mode, fields, account, folders, time window) — none of
    /// them need debouncing, unlike free-text typing, so this awaits the search directly rather
    /// than firing a detached task a caller has no handle on.
    public func updateContext(_ newContext: SearchContext) async {
        guard newContext != context else { return }
        debounceTask?.cancel()
        // A window change on a semantic list that is already showing answers only the semantic
        // query: the server holds the query's vector, so it replies fast and the full-text list
        // would only flash by.
        var withOldWindow = newContext
        withOldWindow.timeWindow = context.timeWindow
        let windowOnly = hasSearched && context.mode == .semantic && withOldWindow == context
        context = newContext
        persistence.saveContext(newContext)
        await run(includeFullText: !windowOnly)
    }

    /// Debounced 300 ms, cancelling whatever was in flight — a fast typist's earlier keystrokes
    /// never race their own later ones for which result lands last.
    public func queryChanged(_ newQuery: String) {
        context.query = newQuery
        persistence.saveContext(context)
        debounceTask?.cancel()
        debounceTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 300_000_000)
            guard !Task.isCancelled else { return }
            await self?.runSearch()
        }
    }

    // MARK: - Running the search

    public func runSearch() async {
        await run(includeFullText: true)
    }

    /// Semantic mode asks twice: the semantic query, and — when `includeFullText` — the same
    /// list's full-text query with the same window, whose answer is shown at once and replaced by
    /// the semantic one when that lands. A response from a superseded run is dropped.
    private func run(includeFullText: Bool) async {
        generation += 1
        let thisGeneration = generation
        searchTask?.cancel()
        fullTextTask?.cancel()

        // Both gates — "search nothing" and "too short to search" — are checked here rather than
        // only by `resultsState` (the screen's own rendering decision), so an empty-folders or
        // too-short query never reaches the network at all.
        guard context.folderIds?.isEmpty != true, context.query.count >= 2 else {
            results = []
            hasSearched = false
            errorMessage = nil
            total = nil
            semanticState = .settled
            return
        }

        isLoading = true
        errorMessage = nil
        let searchContext = context
        guard searchContext.mode == .semantic else {
            semanticState = .settled
            let task = Task { await Self.performSearch(context: searchContext, apiClient: apiClient) }
            searchTask = task
            let outcome = await task.value
            guard thisGeneration == generation else { return }
            apply(outcome)
            return
        }

        semanticState = includeFullText ? .pending : .settled
        let semantic = Task { await Self.performSearch(context: searchContext, apiClient: apiClient) }
        searchTask = semantic
        let fullTextContext = searchContext.fullTextCounterpart
        var fullText: Task<Outcome, Never>?
        if includeFullText {
            let task = Task { await Self.performSearch(context: fullTextContext, apiClient: apiClient) }
            fullText = task
            fullTextTask = task
            Task { [weak self] in
                let outcome = await task.value
                self?.showFullText(outcome, generation: thisGeneration)
            }
        }

        let outcome = await semantic.value
        guard thisGeneration == generation else { return }
        guard case .failure(_, let unavailable) = outcome, unavailable else {
            semanticState = .settled
            apply(outcome)
            return
        }
        // No meaning-based answer: keep (or fetch) the full-text list and say so.
        let fallback: Outcome
        if let fullText {
            fallback = await fullText.value
        } else {
            fallback = await Self.performSearch(context: fullTextContext, apiClient: apiClient)
        }
        guard thisGeneration == generation else { return }
        semanticState = .unavailable
        apply(fallback)
    }

    /// The full-text list shown while the semantic answer is on its way; ignored once the
    /// semantic one has landed or the run was superseded.
    /// A live-event refresh: the list on screen stays put while the query is asked again, so a
    /// semantic list is not swapped for the full-text one on every incoming mail.
    private func reloadInPlace() async {
        await run(includeFullText: context.mode != .semantic)
    }

    private func showFullText(_ outcome: Outcome, generation shownGeneration: Int) {
        guard shownGeneration == generation, semanticState == .pending, case .success(let page) = outcome else {
            return
        }
        results = page.results
        hasMore = false
        nextCursor = nil
        total = page.total
        hasSearched = true
        reportDebugState()
    }

    private func apply(_ outcome: Outcome) {
        switch outcome {
        case .success(let page):
            results = page.results
            hasMore = page.hasMore
            nextCursor = page.nextCursor
            total = page.total
        case .failure(let message, _):
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
        /// `semanticUnavailable`: the server answered 503 to a semantic query.
        case failure(String, semanticUnavailable: Bool)
    }

    private struct Page {
        let results: [MVSearchHit]
        let hasMore: Bool
        let nextCursor: String?
        let total: Int?
    }

    /// `static`, capturing nothing but its arguments — a superseded search's result is discarded
    /// by `runSearch`'s generation check rather than by cancelling a half-built request.
    private static func performSearch(
        context: SearchContext, apiClient: MVApiClient, before: String? = nil
    ) async -> Outcome {
        // Resolved per query, so a preset such as "Last 7 days" keeps rolling with the clock.
        let bounds = context.timeWindow?.bounds(now: Date())
        do {
            switch context.mode {
            case .text:
                let response = try await apiClient.search(
                    query: context.query, accountId: context.accountId, folderIds: context.folderIds,
                    fields: context.fields, receivedAfter: bounds?.since, receivedBefore: bounds?.until,
                    before: before.flatMap(UUID.init(uuidString:))
                )
                return .success(
                    Page(
                        results: response.results.map { MVSearchHit(result: $0) }, hasMore: response.hasMore,
                        nextCursor: response.nextCursor,
                        total: response.total)
                )
            case .semantic:
                let response = try await apiClient.semanticSearch(
                    query: context.query, accountId: context.accountId, folderIds: context.folderIds,
                    receivedAfter: bounds?.since, receivedBefore: bounds?.until
                )
                return .success(
                    Page(
                        results: response.results.map { MVSearchHit(result: $0.result, tier: $0.tier) },
                        hasMore: false, nextCursor: nil, total: response.results.count)
                )
            }
        } catch {
            let statusCode: Int? = {
                switch error as? MVError {
                case .detail(_, let code), .http(let code, _): return code
                default: return nil
                }
            }()
            return .failure(error.mvUserMessage, semanticUnavailable: context.mode == .semantic && statusCode == 503)
        }
    }
}

extension SearchStore: ReaderListSource {
    public var rowIds: [UUID] { results.map(\.id) }
    public var hasOlder: Bool { hasMore }
    public var hasNewer: Bool { false }

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
        Task { await self.reloadInPlace() }
    }
}
