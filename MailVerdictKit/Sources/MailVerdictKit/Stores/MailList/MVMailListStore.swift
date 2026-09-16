import Foundation
import Observation

/// One message list — a folder or a unified view. Owns the fetch window (a page around wherever
/// the list opened, older and newer pages on demand, one bounded request to refresh all of it),
/// the unread and quick filters, and selection. Actions go through the connection's
/// `MVIntentLedger`: `rows` is the server's rows with every outstanding intent applied, so an
/// action shows at once, wherever it was taken, and no read landing meanwhile can undo it.
///
/// Scroll position is not here: the list controller owns the viewport and corrects it by the
/// anchor delta (`MVListAnchoring`) on every change to `rows`. `identity` tells it when `rows`
/// became a different list rather than the same list changed.
@Observable
@MainActor
public final class MVMailListStore: ReaderListSource, LiveEventSubscriber, MVIntentObserver {

    public let scope: ListScope
    /// The toggle as the person set it. `identity.threaded` is what the loaded rows were
    /// fetched with — the two differ only while a toggle's first page is in flight.
    public private(set) var threaded: Bool
    public private(set) var unreadOnly: Bool
    public private(set) var identity: MVListIdentity
    /// The rows as the server last gave them.
    private var baseRows: [MessageSummary] = []
    /// The ledger's sequence when the oldest part of `baseRows` was read.
    private var baseSequence = 0
    public private(set) var hasOlder = false
    /// The window does not start at the newest message — it opened around one, or was restored.
    public private(set) var hasNewer = false
    public private(set) var phase: MVListPhase = .loading
    public private(set) var isLoadingOlder = false
    public private(set) var isLoadingNewer = false
    public private(set) var context = MVListContext()
    /// New rows compensated in above the reader in a window at the newest edge.
    public private(set) var newRowsAboveCount = 0
    /// Arrivals recorded while the window does not start at the newest message — never added
    /// to it, only counted.
    public private(set) var pendingArrivalCount = 0
    public private(set) var pendingLanding: MVListLanding?
    /// The row last opened from this list. Back scrolls to reveal the row the reader settled on
    /// only when it differs from this one — returning from the row that was opened leaves the
    /// position exactly as it was.
    public private(set) var openedMessageId: UUID?
    public private(set) var filterText = ""
    public private(set) var isFilterLoading = false
    public private(set) var isSelecting = false
    public private(set) var selection: MVSelection = .empty

    @ObservationIgnored private let backend: any MVMailListBackend
    @ObservationIgnored private let ledger: MVIntentLedger
    @ObservationIgnored private var projected: (key: ProjectionKey, rows: [MessageSummary])?
    /// The `as_of` of the page each row was last read in; absent when that page carried none (an
    /// older server, or quick-filter results).
    @ObservationIgnored private var rowReadAt: [UUID: Date] = [:]
    /// The app-wide reference data, when there is one: the context starts from its last copy so
    /// a list opened again shows badges, avatars and counts at once, and fresh reads go through
    /// it so every screen shares them.
    @ObservationIgnored private let referenceCache: MVReferenceCache?
    @ObservationIgnored private let toasts: MVToastStore?
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let session: MVListSession
    @ObservationIgnored private let positions: MVListPositionStore
    @ObservationIgnored private let initialAroundId: UUID?
    @ObservationIgnored private var generation = 0
    /// Rows read while the unread filter is on keep showing until the list identity changes or
    /// the filter cycles — the web's `keptWhileUnreadIds`.
    @ObservationIgnored private var keptWhileUnread: Set<UUID> = []
    @ObservationIgnored private var pageTask: Task<Void, Never>?
    @ObservationIgnored private var refreshTask: Task<Void, Never>?
    @ObservationIgnored private var refreshAgain = false
    @ObservationIgnored private var filterDebounce: Task<Void, Never>?
    /// The query the filter was last asked for. A response for any other query is stale — typing
    /// back to a query already showing leaves a longer one's request still in flight.
    @ObservationIgnored private var latestFilterRequest: String?
    @ObservationIgnored private var unfiltered:
        (rows: [MessageSummary], sequence: Int, hasOlder: Bool, hasNewer: Bool, identity: MVListIdentity)?
    @ObservationIgnored private var hasStarted = false
    @ObservationIgnored private var wasConnected: Bool?

    public static let filterMinimumLength = 2
    static let filterDebounceNanos: UInt64 = 150_000_000

    public init(
        scope: ListScope, aroundMessageId: UUID? = nil, backend: any MVMailListBackend, ledger: MVIntentLedger,
        toasts: MVToastStore?, defaults: UserDefaults = .standard, session: MVListSession? = nil,
        referenceCache: MVReferenceCache? = nil
    ) {
        let session = session ?? .shared
        let threaded = MVListPreferences.threaded(defaults: defaults)
        let unreadOnly = session.unreadOnly(for: scope)
        self.scope = scope
        self.threaded = threaded
        self.unreadOnly = unreadOnly
        self.identity = MVListIdentity(
            scope: scope, threaded: threaded, unreadOnly: unreadOnly, filterQuery: "", generation: 0
        )
        self.backend = backend
        self.ledger = ledger
        self.referenceCache = referenceCache
        self.toasts = toasts
        self.defaults = defaults
        self.session = session
        self.positions = MVListPositionStore(defaults: defaults)
        self.initialAroundId = aroundMessageId
        ledger.addObserver(self)
    }

    // MARK: - Rows

    private struct ProjectionKey: Equatable {
        let base: [MessageSummary]
        let sequence: Int
        let intents: [MVMailIntent]
        let scope: MVProjectionScope
    }

    /// What the list shows: the server's rows with the ledger's intents applied.
    public var rows: [MessageSummary] {
        let key = ProjectionKey(base: baseRows, sequence: baseSequence, intents: ledger.intents, scope: projectionScope)
        if let projected, projected.key == key { return projected.rows }
        let rows = MVIntentProjection.rows(
            key.base, applying: key.intents, baseSequence: key.sequence, scope: key.scope)
        projected = (key, rows)
        return rows
    }

    /// "2 actions not sent · 1 failed" — actions that need the person, or `nil`.
    public var actionAttentionSummary: String? { ledger.attentionSummary }
    public var hasUnsentActions: Bool { !ledger.unsentIntents.isEmpty }
    public var hasFailedActions: Bool { !ledger.failedIntents.isEmpty }

    /// Actions held past their expiry, sent after all.
    public func sendUnsentActions() {
        ledger.confirmSend(ledger.unsentIntents.map(\.id))
    }

    public func retryFailedActions() {
        ledger.retry(ledger.failedIntents.map(\.id))
    }

    /// Every unsent and failed action given up on, undoing whatever of them may have landed.
    public func discardAttentionActions() {
        ledger.discard((ledger.unsentIntents + ledger.failedIntents).map(\.id))
    }

    /// Open intents on this list's rows that have been waiting long enough to show it.
    public var waitingIntentIds: Set<UUID> { ledger.waitingIds }

    private var projectionScope: MVProjectionScope {
        MVProjectionScope(
            folderIds: Set(scopeFolderIds), threaded: identity.threaded, hasOlder: hasOlder, hasNewer: hasNewer)
    }

    /// The rows as a read that began at `sequence` gave them — the whole window.
    /// Records when the server read these rows.
    private func noteRead(_ rows: [MessageSummary], asOf: Date?) {
        for row in rows { rowReadAt[row.id] = asOf }
    }

    /// How far a conversation acted on from `rows` expands: the newest `as_of` of the pages they
    /// came from, so every member mirrored before one of those reads is included — a reply that
    /// arrived between two reads is swept along, never an older member left behind. `nil`, no
    /// bound, when any row's page carried none.
    private func conversationBound(for rows: [MessageSummary]) -> Date? {
        var newest: Date?
        for row in rows {
            guard let readAt = rowReadAt[row.id] else { return nil }
            newest = max(newest ?? readAt, readAt)
        }
        return newest
    }

    private func setBase(_ rows: [MessageSummary], readAt sequence: Int) {
        baseRows = rows
        baseSequence = sequence
    }

    /// A page read at `sequence` joined to rows read earlier, which stay as old as they were.
    private func extendBase(_ rows: [MessageSummary], readAt sequence: Int) {
        baseRows = rows
        baseSequence = min(baseSequence, sequence)
    }

    public func intentSnapshots(for messageIds: Set<UUID>) -> [MessageSummary] {
        baseRows.filter { messageIds.contains($0.id) }
    }

    public func intentsWillRetire(_ intents: [MVMailIntent]) {
        baseRows = MVIntentProjection.rows(
            baseRows, applying: intents, baseSequence: baseSequence, scope: projectionScope)
    }

    /// Whatever the server derives from a change — counts, conversation rows, a ruling moving
    /// mail — is read again once it has the change.
    public func intentsDidSettle(_ intents: [MVMailIntent]) {
        let accounts = Set(accountIdsInScope)
        if intents.contains(where: { accounts.contains($0.accountId) }) { requestRefresh() }
    }

    // MARK: - ReaderListSource

    public var rowIds: [UUID] { rows.map(\.id) }

    public func loadOlder() async {
        await page(.older)
    }

    public func loadNewer() async {
        await page(.newer)
    }

    /// "{N} Messages": the folder's or unified view's total, or its unread count while only
    /// unread mail is listed. `nil` until that count has loaded.
    public var readerTitle: String? {
        let count: Int?
        switch scope {
        case .folder(_, let folderId):
            count = context.folders[folderId].map { unreadOnly ? $0.unreadCount : $0.totalCount }
        case .unified:
            count = context.unifiedView.map { unreadOnly ? $0.unreadCount : $0.totalCount }
        }
        return count.map { "\($0) \($0 == 1 ? "Message" : "Messages")" }
    }

    /// Rows are projected through the ledger, so a reader paging this list needs no other record of
    /// what an intent has taken out of it.
    public var projectsIntents: Bool { true }

    /// A row was opened from this list.
    public func didOpen(_ messageId: UUID) {
        openedMessageId = messageId
    }

    // MARK: - Loading

    /// Loads the first page (around `aroundMessageId`, or around the saved position, or at the
    /// newest edge) and the list's context. Idempotent: SwiftUI may run a view's task again.
    public func start() async {
        guard !hasStarted else { return }
        hasStarted = true
        let restoring = initialAroundId == nil ? positions.load(scope: scope, threaded: threaded) : nil
        seedContextFromCache()
        async let contextLoad: Void = loadContext()
        await loadFirstPage(aroundId: initialAroundId, restoring: restoring, generation: generation)
        await contextLoad
    }

    public func retry() async {
        await replaceList()
    }

    public func consumeLanding() -> MVListLanding? {
        defer { pendingLanding = nil }
        return pendingLanding
    }

    private func loadFirstPage(
        aroundId: UUID?, restoring: MVListPositionStore.Position?, generation expected: Int
    ) async {
        if rows.isEmpty { phase = .loading }
        let target = aroundId ?? restoring.flatMap { $0.atTop ? nil : $0.anchor.rowId }
        let threaded = self.threaded
        let unreadOnly = self.unreadOnly
        let readAt = ledger.sequence
        do {
            var page: MessageListResponse
            var landedAround = false
            if let target {
                do {
                    page = try await backend.fetchListPage(
                        scope: scope, threaded: threaded, unreadOnly: unreadOnly, cursor: .around(target),
                        limit: MVMailListWindow.pageSize
                    )
                    landedAround = true
                } catch  where Self.isNotFound(error) {
                    // Not a member of this list (any more): the newest edge is where the reader
                    // would otherwise land.
                    page = try await backend.fetchListPage(
                        scope: scope, threaded: threaded, unreadOnly: unreadOnly, cursor: .newest,
                        limit: MVMailListWindow.pageSize
                    )
                }
            } else {
                page = try await backend.fetchListPage(
                    scope: scope, threaded: threaded, unreadOnly: unreadOnly, cursor: .newest,
                    limit: MVMailListWindow.pageSize
                )
            }
            guard generation == expected else { return }
            noteRead(page.messages, asOf: page.asOf)
            setBase(page.messages, readAt: readAt)
            hasOlder = page.hasMore
            hasNewer = page.hasMoreNewer
            identity = MVListIdentity(
                scope: scope, threaded: threaded, unreadOnly: unreadOnly, filterQuery: "", generation: expected
            )
            phase = .loaded
            guard landedAround, let target else { return }
            if aroundId == nil, let anchor = restoring?.anchor, rows.contains(where: { $0.id == anchor.rowId }) {
                pendingLanding = .restore(anchor)
            } else if let rowId = await representativeRowId(for: target), generation == expected {
                pendingLanding = .revealInUpperThird(rowId)
            }
        } catch {
            guard generation == expected else { return }
            if rows.isEmpty {
                phase = .failed(message: error.mvUserMessage, detail: error.mvTechnicalDetail)
            } else {
                showError("Could not load messages: \(error.mvUserMessage)")
            }
        }
    }

    /// Grouped by conversation, the server centres an around page on the row representing the
    /// target's conversation — a different id — so the row is found by thread instead.
    private func representativeRowId(for target: UUID) async -> UUID? {
        if rows.contains(where: { $0.id == target }) { return target }
        guard identity.threaded, let location = try? await backend.fetchLocation(messageId: target) else {
            return nil
        }
        return rows.first { $0.threadId == location.threadId }?.id
    }

    private enum PageDirection { case older, newer }

    private func page(_ direction: PageDirection) async {
        while let running = pageTask { await running.value }
        switch direction {
        case .older: guard hasOlder, phase == .loaded, !rows.isEmpty else { return }
        case .newer: guard hasNewer, phase == .loaded, !rows.isEmpty, !isFilterActive else { return }
        }
        let task = Task { [weak self] in
            guard let self else { return }
            await self.fetchPage(direction)
            self.pageTask = nil
        }
        pageTask = task
        await task.value
    }

    private func fetchPage(_ direction: PageDirection) async {
        let started = identity
        let readAt = ledger.sequence
        switch direction {
        case .older: isLoadingOlder = true
        case .newer: isLoadingNewer = true
        }
        defer {
            isLoadingOlder = false
            isLoadingNewer = false
        }
        do {
            if isFilterActive {
                let response = try await backend.fetchFilterPage(
                    query: started.filterQuery, accountId: filterAccountId, folderIds: filterFolderIds,
                    unreadOnly: started.unreadOnly, before: baseRows.last?.id, limit: MVMailListWindow.pageSize
                )
                guard identity == started else { return }
                let results = response.results.map(MessageSummary.init)
                noteRead(results, asOf: nil)
                extendBase(
                    MVMailListWindow.appendingOlder(results, to: baseRows),
                    readAt: readAt)
                hasOlder = response.hasMore
                return
            }
            switch direction {
            case .older:
                guard let last = baseRows.last else { return }
                let response = try await backend.fetchListPage(
                    scope: scope, threaded: started.threaded, unreadOnly: started.unreadOnly,
                    cursor: .olderThan(last.id), limit: MVMailListWindow.pageSize
                )
                guard identity == started else { return }
                noteRead(response.messages, asOf: response.asOf)
                extendBase(MVMailListWindow.appendingOlder(response.messages, to: baseRows), readAt: readAt)
                hasOlder = response.hasMore
            case .newer:
                guard let first = baseRows.first else { return }
                let response = try await backend.fetchListPage(
                    scope: scope, threaded: started.threaded, unreadOnly: started.unreadOnly,
                    cursor: .newerThan(first.id), limit: MVMailListWindow.pageSize
                )
                guard identity == started else { return }
                noteRead(response.messages, asOf: response.asOf)
                extendBase(MVMailListWindow.prependingNewer(response.messages, to: baseRows), readAt: readAt)
                hasNewer = response.hasMoreNewer
                if !hasNewer { await catchUpAfterReachingNewestEdge(started) }
            }
        } catch {
            // Left as it was: the next scroll toward the edge asks again.
        }
    }

    /// Something may have arrived between the page that reached the newest edge being requested
    /// and it landing; one more read closes that gap before the window counts as caught up.
    private func catchUpAfterReachingNewestEdge(_ started: MVListIdentity) async {
        guard pendingArrivalCount > 0 else { return }
        pendingArrivalCount = 0
        let readAt = ledger.sequence
        guard let first = baseRows.first,
            let response = try? await backend.fetchListPage(
                scope: scope, threaded: started.threaded, unreadOnly: started.unreadOnly,
                cursor: .newerThan(first.id), limit: MVMailListWindow.pageSize
            ),
            identity == started
        else { return }
        noteRead(response.messages, asOf: response.asOf)
        extendBase(MVMailListWindow.prependingNewer(response.messages, to: baseRows), readAt: readAt)
    }

    // MARK: - Refreshing

    /// Re-reads the whole loaded window in one request. Never more than one in flight: a
    /// request arriving meanwhile queues exactly one more read. Awaitable for pull to refresh.
    public func refresh() async {
        if let running = refreshTask {
            refreshAgain = true
            await running.value
            return
        }
        let task = Task { [weak self] in
            guard let self else { return }
            repeat {
                self.refreshAgain = false
                while let paging = self.pageTask { await paging.value }
                await self.refreshOnce()
            } while self.refreshAgain
            self.refreshTask = nil
        }
        refreshTask = task
        await task.value
    }

    public func requestRefresh() {
        Task { [weak self] in await self?.refresh() }
    }

    private func refreshOnce() async {
        guard phase == .loaded, !isFilterActive, !baseRows.isEmpty else { return }
        let started = identity
        let readAt = ledger.sequence
        let preserve = started.unreadOnly ? keptWhileUnread : []
        // A row kept while the unread filter is on stays as the reader last saw it — read — even
        // once the change that made it so has left the ledger.
        let shown = Dictionary(rows.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let current = baseRows.map { preserve.contains($0.id) ? shown[$0.id] ?? $0 : $0 }
        let limit = MVMailListWindow.refreshLimit(loadedRows: baseRows.count)
        do {
            if hasNewer {
                guard let last = baseRows.last else { return }
                let response = try await backend.fetchListPage(
                    scope: scope, threaded: started.threaded, unreadOnly: started.unreadOnly,
                    cursor: .newerThan(last.id), limit: limit
                )
                guard identity == started else { return }
                let merged = MVMailListWindow.mergeRefreshedFromBelow(
                    current: current, freshAboveLast: response.messages, freshHasMoreNewer: response.hasMoreNewer,
                    preserveIds: preserve
                )
                noteRead(response.messages, asOf: response.asOf)
                setBase(merged.rows, readAt: readAt)
                hasNewer = merged.hasNewer
            } else {
                let response = try await backend.fetchListPage(
                    scope: scope, threaded: started.threaded, unreadOnly: started.unreadOnly, cursor: .newest,
                    limit: limit
                )
                guard identity == started else { return }
                let merged = MVMailListWindow.mergeRefreshed(
                    current: current, fresh: response.messages, freshHasMore: response.hasMore,
                    currentHasMore: hasOlder, preserveIds: preserve
                )
                noteRead(response.messages, asOf: response.asOf)
                setBase(merged.rows, readAt: readAt)
                hasOlder = merged.hasMore
            }
        } catch {
            // The next change, foreground return or reconnect refreshes again.
        }
    }

    public func pullToRefresh() async {
        for accountId in accountIdsInScope {
            try? await backend.requestSync(accountId: accountId)
        }
        await refresh()
        await loadContext()
    }

    /// The last copy of everything the context needs, before any request: a list opened again
    /// draws its rows with badges, avatars and the title straight away.
    private func seedContextFromCache() {
        guard let cache = referenceCache else { return }
        var next = context
        if let accounts = cache.cachedAccounts { next.accounts = Self.byId(accounts) }
        if case .unified(let viewId, _) = scope, let views = cache.cachedUnifiedViews {
            next.unifiedView = views.first { $0.id == viewId }
        }
        let accountIds = accountIdsIn(next)
        next.folders = Self.byId(accountIds.flatMap { cache.cachedFolders(accountId: $0) ?? [] })
        next.avatarPhotos = Self.avatarPhotos(accountIds.compactMap { cache.cachedPhotoIndex(accountId: $0) })
        context = next
    }

    /// Every part of the context read at once — accounts, the view, each account's folders and
    /// photo index, the dead outbox — rather than one request after another. A part whose
    /// request fails keeps what the context already had.
    private func loadContext() async {
        async let accountsLoad = freshAccounts()
        async let deadLoad = try? backend.fetchDeadOutbox()
        var unifiedView = context.unifiedView
        if case .unified(let viewId, _) = scope, let views = await freshUnifiedViews() {
            unifiedView = views.first { $0.id == viewId }
        }
        let accountIds: [UUID]
        switch scope {
        case .folder(let accountId, _): accountIds = [accountId]
        case .unified: accountIds = Array(Set(unifiedView?.folders.map(\.accountId) ?? []))
        }
        async let foldersLoad = freshFolders(accountIds)
        async let photosLoad = freshPhotoIndexes(accountIds)
        let (accounts, dead, folders, photoIndexes) = await (accountsLoad, deadLoad, foldersLoad, photosLoad)

        var next = context
        if let accounts { next.accounts = Self.byId(accounts) }
        next.unifiedView = unifiedView
        var mergedFolders = next.folders.filter { accountIds.contains($0.value.accountId) }
        for (accountId, list) in folders {
            mergedFolders = mergedFolders.filter { $0.value.accountId != accountId }
            for folder in list { mergedFolders[folder.id] = folder }
        }
        next.folders = mergedFolders
        if case .folder(let accountId, _) = scope {
            next.neverConnectedError = nil
            if let account = next.accounts[accountId], account.state == "error",
                let status = try? await backend.fetchSyncStatus(accountId: accountId), status.lastFullSync == nil
            {
                next.neverConnectedError = account.stateError ?? "This account has never connected"
            }
        }
        if let dead {
            let scopedIds = Set(accountIds)
            let scoped = dead.filter { scopedIds.contains($0.accountId) }
            next.deadOutboxCount = scoped.count
            next.deadOutboxAccountNames = Set(scoped.map(\.accountId)).compactMap { next.accounts[$0]?.name }.sorted()
        }
        if !photoIndexes.isEmpty || accountIds.isEmpty {
            next.avatarPhotos = Self.avatarPhotos(Array(photoIndexes.values))
        }
        context = next
    }

    private func freshAccounts() async -> [AccountResponse]? {
        if let referenceCache { return await referenceCache.fetchAccounts() }
        return try? await backend.fetchAccounts()
    }

    private func freshUnifiedViews() async -> [UnifiedFolderResponse]? {
        if let referenceCache { return await referenceCache.fetchUnifiedViews() }
        return try? await backend.fetchUnifiedViews()
    }

    /// Each account's folders, keyed by account — an account whose request failed is absent.
    private func freshFolders(_ accountIds: [UUID]) async -> [UUID: [FolderResponse]] {
        await withTaskGroup(of: (UUID, [FolderResponse]?).self) { group in
            for accountId in accountIds {
                group.addTask { (accountId, await self.freshFolders(accountId: accountId)) }
            }
            var result: [UUID: [FolderResponse]] = [:]
            for await (accountId, folders) in group { result[accountId] = folders }
            return result
        }
    }

    /// A failed read falls back to the cache's last copy, so one account's blip does not blank
    /// its rows' folder roles.
    private func freshFolders(accountId: UUID) async -> [FolderResponse]? {
        if let referenceCache {
            return await referenceCache.fetchFolders(accountId: accountId)
                ?? referenceCache.cachedFolders(accountId: accountId)
        }
        return try? await backend.fetchFolders(accountId: accountId)
    }

    private func freshPhotoIndexes(_ accountIds: [UUID]) async -> [UUID: ContactPhotoIndexResponse] {
        await withTaskGroup(of: (UUID, ContactPhotoIndexResponse?).self) { group in
            for accountId in accountIds {
                group.addTask { (accountId, await self.freshPhotoIndex(accountId: accountId)) }
            }
            var result: [UUID: ContactPhotoIndexResponse] = [:]
            for await (accountId, index) in group { result[accountId] = index }
            return result
        }
    }

    private func freshPhotoIndex(accountId: UUID) async -> ContactPhotoIndexResponse? {
        if let referenceCache {
            return await referenceCache.fetchPhotoIndex(accountId: accountId)
                ?? referenceCache.cachedPhotoIndex(accountId: accountId)
        }
        return try? await backend.fetchContactPhotoIndex(accountId: accountId)
    }

    private static func byId<T: Identifiable>(_ items: [T]) -> [T.ID: T] {
        Dictionary(items.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    }

    private static func avatarPhotos(_ indexes: [ContactPhotoIndexResponse]) -> [String: MVAvatarPhotoSource] {
        var photos: [String: MVAvatarPhotoSource] = [:]
        for index in indexes {
            for (email, entry) in index.byEmail { photos[email.lowercased()] = entry.avatarSource }
        }
        return photos
    }

    // MARK: - Live updates

    public func setConnected(_ connected: Bool) {
        let wasDisconnected = wasConnected == false
        wasConnected = connected
        // A reconnect may have missed events; the window is re-read rather than trusted.
        if connected && wasDisconnected { requestRefresh() }
    }

    public func apply(_ invalidations: [MVLiveInvalidation]) {
        var needsRefresh = false
        var needsContext = false
        for invalidation in invalidations {
            switch invalidation {
            case .resync:
                needsRefresh = true
                needsContext = true
            case .mailNew(_, let folderId, let messageId):
                guard concerns(folderId) else { continue }
                needsRefresh = true
                if hasNewer, !isFilterActive, !(messageId.map(containsRow) ?? false) {
                    pendingArrivalCount += 1
                }
            case .mailUpdated(_, let folderId, let messageId, _):
                if concerns(folderId) || (messageId.map(containsRow) ?? false) { needsRefresh = true }
            case .mailDeleted(_, _, let messageId):
                if let messageId, containsRow(messageId) {
                    baseRows.removeAll { $0.id == messageId }
                    needsRefresh = true
                }
            case .folderSynced(_, let folderId):
                if concerns(folderId) { needsRefresh = true }
            case .verdictIssued(_, let messageId, _):
                if messageId.map(containsRow) ?? false { needsRefresh = true }
            case .outboxUpdated(let payload):
                if payload.status == "sent" { needsRefresh = true }
                if payload.status == "dead" { needsContext = true }
            case .foldersChanged, .accountsChanged:
                needsContext = true
            default:
                continue
            }
        }
        if needsRefresh { requestRefresh() }
        if needsContext { Task { [weak self] in await self?.loadContext() } }
    }

    private func concerns(_ folderId: UUID?) -> Bool {
        guard let folderId else { return true }
        switch scope {
        case .folder(_, let own): return own == folderId
        case .unified: return context.unifiedView.map { $0.folders.contains { $0.folderId == folderId } } ?? true
        }
    }

    private func containsRow(_ id: UUID) -> Bool {
        rows.contains { $0.id == id }
    }

    // MARK: - Toggles, filters, jumps

    public func setThreaded(_ threaded: Bool) async {
        guard threaded != self.threaded else { return }
        self.threaded = threaded
        MVListPreferences.setThreaded(threaded, defaults: defaults)
        await replaceList()
    }

    public func setUnreadOnly(_ unreadOnly: Bool) async {
        guard unreadOnly != self.unreadOnly else { return }
        self.unreadOnly = unreadOnly
        session.setUnreadOnly(unreadOnly, for: scope)
        await replaceList()
    }

    /// The "N New Messages" capsule in a window that does not start at the newest message: the
    /// window is replaced with a fresh newest page rather than paged all the way up.
    public func jumpToLatest() async {
        await replaceList()
    }

    public func clearNewRowsAbove() {
        if newRowsAboveCount != 0 { newRowsAboveCount = 0 }
    }

    public func noteNewRowsAbove(_ count: Int) {
        guard count > 0 else { return }
        newRowsAboveCount += count
    }

    /// A different list in the same scope: rows stay on screen until the new first page lands,
    /// then both change together.
    private func replaceList() async {
        generation += 1
        let expected = generation
        filterDebounce?.cancel()
        filterText = ""
        isFilterLoading = false
        unfiltered = nil
        keptWhileUnread = []
        selection = .empty
        isSelecting = false
        pendingArrivalCount = 0
        newRowsAboveCount = 0
        await loadFirstPage(aroundId: nil, restoring: nil, generation: expected)
    }

    public var isFilterActive: Bool { !identity.filterQuery.isEmpty }

    /// The trimmed query, or empty below the minimum length the filter needs.
    public static func effectiveFilterQuery(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.count >= filterMinimumLength ? trimmed : ""
    }

    public func setFilterText(_ text: String) {
        filterText = text
        filterDebounce?.cancel()
        let query = Self.effectiveFilterQuery(text)
        filterDebounce = Task { [weak self] in
            try? await Task.sleep(nanoseconds: Self.filterDebounceNanos)
            guard !Task.isCancelled else { return }
            await self?.applyFilter(query: query)
        }
    }

    private var filterFolderIds: [UUID] {
        switch scope {
        case .folder(_, let folderId): return [folderId]
        case .unified: return context.unifiedView?.folders.map(\.folderId) ?? []
        }
    }

    private var filterAccountId: UUID? {
        if case .folder(let accountId, _) = scope { return accountId }
        return nil
    }

    /// Filtering is a different list, starting at the top; clearing it returns the unfiltered
    /// rows (and, through `identity`, the controller's saved position in them).
    func applyFilter(query: String) async {
        latestFilterRequest = query
        guard query != identity.filterQuery else {
            // Typed back to the query already showing, while a longer one was in flight.
            isFilterLoading = false
            return
        }
        if query.isEmpty {
            isFilterLoading = false
            guard let saved = unfiltered else { return }
            unfiltered = nil
            baseRows = saved.rows
            baseSequence = saved.sequence
            hasOlder = saved.hasOlder
            hasNewer = saved.hasNewer
            identity = saved.identity
            phase = .loaded
            requestRefresh()
            return
        }
        let folderIds = filterFolderIds
        guard !folderIds.isEmpty, phase == .loaded || unfiltered != nil else { return }
        if unfiltered == nil { unfiltered = (baseRows, baseSequence, hasOlder, hasNewer, identity) }
        generation += 1
        let started = MVListIdentity(
            scope: scope, threaded: identity.threaded, unreadOnly: unreadOnly, filterQuery: query,
            generation: generation
        )
        selection = .empty
        isFilterLoading = true
        let readAt = ledger.sequence
        do {
            let response = try await backend.fetchFilterPage(
                query: query, accountId: filterAccountId, folderIds: folderIds, unreadOnly: unreadOnly, before: nil,
                limit: MVMailListWindow.pageSize
            )
            guard generation == started.generation, latestFilterRequest == query else { return }
            identity = started
            let results = response.results.map(MessageSummary.init)
            noteRead(results, asOf: nil)
            setBase(results, readAt: readAt)
            hasOlder = response.hasMore
            hasNewer = false
            phase = .loaded
        } catch {
            guard generation == started.generation, latestFilterRequest == query else { return }
            // The next keystroke cancelled this request before its own request began.
            if !error.mvIsCancellation { showError("Could not filter: \(error.mvUserMessage)") }
        }
        isFilterLoading = false
    }

    // MARK: - Position

    /// Saves where the reader is for the next launch. `atTop` must come from geometry at the
    /// moment of saving, and is false whenever newer rows exist unloaded.
    public func savePosition(anchor: MVListAnchor?, atTop: Bool) {
        guard !isFilterActive, phase == .loaded else { return }
        let position = anchor.map { MVListPositionStore.Position(anchor: $0, atTop: atTop && !hasNewer) }
        positions.save(position, scope: scope, threaded: identity.threaded)
    }

    // MARK: - Presentation

    public var isUnified: Bool {
        if case .unified = scope { return true }
        return false
    }

    public var title: String {
        switch scope {
        case .folder(let accountId, let folderId):
            let folder = context.folders[folderId].map {
                folderDisplayName(imapName: $0.imapName, displayName: $0.displayName, specialUse: $0.specialUse)
            }
            return [folder, context.accounts[accountId]?.name].compactMap { $0 }.joined(separator: " ")
        case .unified(_, let name):
            return [context.unifiedView?.emoji, context.unifiedView?.unifiedName ?? name].compactMap { $0 }
                .joined(separator: " ")
        }
    }

    /// `connection` is the live stream's own state (`LiveEventHub.connectionState`).
    public func subtitle(now: Date = Date(), connection: MVConnectionState = .connected) -> String {
        switch connection {
        case .reconnecting: return "Connecting…"
        case .disconnected: return "Offline"
        case .connected: break
        }
        if let waiting = ledger.waitingSummary { return waiting }
        if unreadOnly { return "Filtered by: Unread" }
        let synced = scopeFolderIds.compactMap { context.folders[$0]?.lastSyncedAt }.max()
        guard let synced else { return "" }
        return "Updated \(MVDateFormat.relativeAgo(synced, now: now))"
    }

    public var emptyStateMessage: String {
        if isFilterActive { return "No messages match this filter" }
        if unreadOnly { return "No unread messages here" }
        return isUnified ? "No messages in this view" : "No messages in this folder"
    }

    /// "N messages could not be sent — check SMTP settings on …", or `nil` with nothing dead.
    public var deadOutboxBanner: String? {
        guard context.deadOutboxCount > 0 else { return nil }
        let count = context.deadOutboxCount
        let noun = count == 1 ? "message" : "messages"
        let accounts = context.deadOutboxAccountNames.joined(separator: ", ")
        return "\(count) \(noun) could not be sent — check SMTP settings on \(accounts)"
    }

    public var newMessagesCapsuleCount: Int {
        hasNewer ? pendingArrivalCount : newRowsAboveCount
    }

    public func specialUse(of row: MessageSummary) -> String? {
        context.folders[row.folderId]?.specialUse
            ?? context.unifiedView?.folders.first { $0.folderId == row.folderId }?.specialUse
    }

    public func isInTrash(_ row: MessageSummary) -> Bool { specialUse(of: row) == "trash" }
    public func isInJunk(_ row: MessageSummary) -> Bool { specialUse(of: row) == "junk" }
    public func isInArchive(_ row: MessageSummary) -> Bool { specialUse(of: row) == "archive" }
    public func isDraft(_ row: MessageSummary) -> Bool { row.isDraft || specialUse(of: row) == "drafts" }

    /// Grouped by conversation, a row counts every unread message in its thread, so an older
    /// unread reply behind a read newest one still makes the row unread (the web's
    /// `isRowUnread`).
    public static func isRowUnread(_ row: MessageSummary) -> Bool {
        !row.isSeen || (row.unreadInThread ?? 0) > 0
    }

    public func row(id: UUID) -> MessageSummary? {
        rows.first { $0.id == id }
    }

    public func rowData(for row: MessageSummary, now: Date = Date()) -> MVMailRowData {
        .plain(
            id: row.id, isUnread: Self.isRowUnread(row), senderName: extractSenderName(row.fromAddr),
            dateText: MVDateFormat.relativeDate(row.receivedAt, now: now), pendingSync: row.pendingSync,
            subject: row.subject ?? "(no subject)", threadCount: identity.threaded ? row.threadCount : nil,
            isAnswered: row.isAnswered, hasAttachments: row.hasAttachments, verdictIsSpam: row.verdictIsSpam == true,
            isStarred: row.isFlagged, snippet: row.snippet, snippetMarksMatches: isFilterActive,
            avatarIdentity: row.fromAddr.map(extractEmail) ?? extractSenderName(row.fromAddr),
            avatarPhoto: context.avatarPhotos[extractEmail(row.fromAddr).lowercased()],
            unifiedAccountEmoji: isUnified ? context.accounts[row.accountId]?.emoji : nil,
            actionState: ledger.rowState(for: row.id)
        )
    }

    /// The Options set's input for `row` on `surface` — the swipe sheet and context menu both
    /// build from `MessageActionSet.actions(for:)` with this.
    public func actionContext(for row: MessageSummary, surface: MVMessageActionSurface) -> MVMessageContext {
        MVMessageContext(
            surface: surface, source: .list, isRead: !Self.isRowUnread(row), isStarred: row.isFlagged,
            isInTrash: isInTrash(row), isInJunk: isInJunk(row),
            verdict: row.verdictIsSpam.map { MVMessageVerdictContext(isSpam: $0, modelUsed: nil) }
        )
    }

    private var scopeFolderIds: [UUID] {
        switch scope {
        case .folder(_, let folderId): return [folderId]
        case .unified: return context.unifiedView?.folders.map(\.folderId) ?? []
        }
    }

    private var accountIdsInScope: [UUID] { accountIdsIn(context) }

    private func accountIdsIn(_ context: MVListContext) -> [UUID] {
        switch scope {
        case .folder(let accountId, _): return [accountId]
        case .unified: return Array(Set(context.unifiedView?.folders.map(\.accountId) ?? []))
        }
    }

    // MARK: - Single-message actions

    /// Applies `action` to one row optimistically and sends it. Returns straight after the
    /// optimistic change, so a swipe's completion can run against rows that already reflect it.
    /// Reply, Reply All and Forward are the caller's (they open the composer), as are the
    /// confirmation Delete Forever needs and the Move picker `.moveTo` needs.
    public func perform(_ action: MVMessageUIAction, on rowId: UUID, target: MVMoveTarget? = nil) {
        guard let row = row(id: rowId) else { return }
        switch action {
        case .confirmVerdict, .correctVerdict:
            guard let verdict = row.verdictIsSpam else { return }
            sendVerdictFeedback(row, isSpam: action == .confirmVerdict ? verdict : !verdict)
            return
        case .archive where isInArchive(row):
            toasts?.show(MVToast(variant: .info, message: "Already in Archive", duration: 3))
            return
        case .markRead where identity.threaded && Self.hasOtherUnreadInConversation(row):
            markConversationRead(row)
            return
        default:
            break
        }
        let targetFolderId = target?.folderId(forAccount: row.accountId)
        guard let bulk = MailActionService.bulkAction(for: action, targetFolderId: targetFolderId) else { return }
        if bulk == .markRead { keptWhileUnread.insert(rowId) }
        if bulk == .markUnread { Task { await MVExplicitUnreadTracker.shared.markExplicit(rowId) } }
        ledger.enqueue(
            MVIntentRequest(
                accountId: row.accountId, action: bulk, targetFolderId: targetFolderId, messageIds: [rowId],
                originFolderIds: [rowId: row.folderId], snapshots: [row]),
            undoToast: bulk.undoToastTitle)
    }

    /// Reading a conversation row clears every unread message it counts, not only the newest one
    /// it stands for (port of the web's `useMarkConversationRead`).
    private func markConversationRead(_ row: MessageSummary) {
        keptWhileUnread.insert(row.id)
        ledger.enqueue(
            MVIntentRequest(
                accountId: row.accountId, action: .markRead, messageIds: [row.id],
                delivery: .conversationRead(folderIds: scopeFolderIds), originFolderIds: [row.id: row.folderId]))
    }

    private func sendVerdictFeedback(_ row: MessageSummary, isSpam: Bool) {
        Task { [weak self] in
            guard let self else { return }
            do {
                try await self.backend.sendVerdictFeedback(messageId: row.id, accountId: row.accountId, isSpam: isSpam)
                self.toasts?.show(MVToast(variant: .success, message: "Thanks — feedback recorded", duration: 3))
            } catch {
                self.showError("Could not send feedback: \(error.mvUserMessage)")
            }
            // A ruling can move the message.
            self.requestRefresh()
        }
    }

    /// A conversation row counting unread messages besides its own.
    static func hasOtherUnreadInConversation(_ row: MessageSummary) -> Bool {
        let ownUnread = row.isSeen ? 0 : 1
        return (row.unreadInThread ?? 0) - ownUnread > 0
    }

    // MARK: - Selection

    public var selectionScope: MVSelectionScope {
        MVSelectionScope(listScope: scope, threaded: identity.threaded)
    }

    /// The selection as it applies to the list on screen — never the raw value.
    public var effectiveSelection: MVSelection {
        selection.scoped(to: selectionScope)
    }

    public var selectionTitle: String {
        MVSelectionText.title(for: effectiveSelection, threaded: identity.threaded)
    }

    public var selectionScopeNote: String? {
        MVSelectionText.scopeNote(for: effectiveSelection, threaded: identity.threaded)
    }

    public func setSelecting(_ selecting: Bool) {
        isSelecting = selecting
        if !selecting { selection = .empty }
    }

    public func toggleSelection(of rowId: UUID) {
        guard let row = row(id: rowId) else { return }
        selection = effectiveSelection.toggling(MVSelectableRow(row), in: selectionScope)
        isSelecting = true
    }

    public func isSelected(_ rowId: UUID) -> Bool {
        guard let row = row(id: rowId) else { return false }
        return effectiveSelection.isSelected(MVSelectableRow(row))
    }

    /// Select All: a server-minted predicate over the whole folder (every unread message while
    /// the unread filter is on). A unified view has no single folder to mint over, and a quick
    /// filter's results are not the folder, so both tick the loaded rows instead.
    public func selectAll() async {
        isSelecting = true
        guard case .folder(let accountId, let folderId) = scope, !isFilterActive else {
            selection = .explicit(rows.map(MVSelectableRow.init), in: selectionScope)
            return
        }
        let filter: MVSelectionFilter = unreadOnly ? .unread : .all
        let scopeAtRequest = selectionScope
        do {
            let snapshot = try await backend.fetchSelectionSnapshot(
                accountId: accountId, folderId: folderId, filter: filter
            )
            guard selectionScope == scopeAtRequest, isSelecting else { return }
            let predicate = MVSelectionPredicate(
                accountId: accountId, folderId: folderId, filter: filter, snapshotAt: snapshot.snapshotAt,
                count: snapshot.count
            )
            selection = .all(predicate, in: scopeAtRequest)
        } catch {
            showError("Could not select all: \(error.mvUserMessage)")
        }
    }

    public func deselectAll() {
        selection = .empty
    }

    /// Runs a bulk action on the selection. An explicit selection is applied optimistically and
    /// offered back with Undo where the action has one; a predicate is resolved server-side over
    /// however many messages match, so the list is re-read from the newest edge afterwards.
    /// Confirmation (`MVBulkRequestBuilder.needsConfirmation`) is the caller's, before this.
    public func performBulk(_ action: MVBulkAction, target: MVMoveTarget? = nil) async {
        let current = effectiveSelection
        guard !current.isEmpty else { return }
        let built = MVBulkRequestBuilder.plans(
            for: current, action: action, targetFolderId: { target?.folderId(forAccount: $0) }
        )
        let count = current.count
        if current.predicate != nil {
            toasts?.show(
                MVToast(
                    variant: .info, message: "Applying \(action.phrase) to \(count) messages — this can take a while",
                    duration: 6
                )
            )
        }

        selection = .empty
        isSelecting = false
        if !built.skippedAccountIds.isEmpty {
            toasts?.show(
                MVToast(
                    variant: .warning,
                    message: "Some messages were not moved — the destination does not exist in every account",
                    duration: 6
                )
            )
        }
        guard current.predicate == nil else {
            await performPredicateBulk(action, plans: built.plans)
            return
        }

        let ids = Set(current.included.keys)
        let originals = rows.filter { ids.contains($0.id) }
        if action == .markRead { keptWhileUnread.formUnion(ids) }
        if action == .markUnread {
            Task { for id in ids { await MVExplicitUnreadTracker.shared.markExplicit(id) } }
        }
        let intentIds = built.plans.map { plan in
            let planIds = plan.request.ids ?? []
            let planOriginals = originals.filter { planIds.contains($0.id) }
            return ledger.enqueue(
                MVIntentRequest(
                    accountId: plan.accountId, action: action, targetFolderId: plan.request.targetFolderId,
                    messageIds: planIds, delivery: .bulk(expandThreads: plan.request.expandThreads),
                    originFolderIds: Dictionary(
                        planOriginals.map { ($0.id, $0.folderId) }, uniquingKeysWith: { first, _ in first }),
                    snapshots: planOriginals,
                    seenThrough: plan.request.expandThreads ? conversationBound(for: planOriginals) : nil))
        }
        if let phrase = action.bulkUndoPhrase, !intentIds.isEmpty {
            // Offered at once, like a single action's: undoing what has not been sent yet simply
            // cancels it. A conversation row counts as one conversation, whatever it expands to.
            let count = ids.count
            let noun =
                identity.threaded
                ? (count == 1 ? "conversation" : "conversations") : (count == 1 ? "message" : "messages")
            ledger.showUndo("\(count) \(noun) \(phrase)", for: intentIds)
        }
    }

    /// A predicate is resolved server-side over however many messages match, so nothing is
    /// projected: the list is read again from the newest edge once it has run.
    private func performPredicateBulk(_ action: MVBulkAction, plans: [MVBulkRequestPlan]) async {
        do {
            for plan in plans {
                let response = try await backend.sendBulkAction(accountId: plan.accountId, request: plan.request)
                guard response.success else {
                    throw MVError.detail(
                        response.errors.joined(separator: "; ").isEmpty
                            ? "Could not \(action.phrase)" : response.errors.joined(separator: "; "),
                        statusCode: 200
                    )
                }
            }
        } catch {
            showError("Could not \(action.phrase): \(error.mvUserMessage)")
        }
        await replaceList()
    }

    // MARK: - Whole-folder actions

    public func markAllAsRead() async {
        guard case .folder(let accountId, let folderId) = scope else { return }
        do {
            let snapshot = try await backend.fetchSelectionSnapshot(
                accountId: accountId, folderId: folderId, filter: .all)
            let unread = context.folders[folderId]?.unreadCount ?? 0
            if unread > 0 {
                toasts?.show(
                    MVToast(variant: .info, message: "Marking \(unread) messages — this can take a while", duration: 5)
                )
            }
            _ = try await backend.sendBulkAction(
                accountId: accountId,
                request: BulkActionRequest(
                    action: .markRead,
                    scope: BulkActionScope(folderId: folderId, filter: "all", snapshotAt: snapshot.snapshotAt)
                )
            )
        } catch {
            showError("Could not mark as read: \(error.mvUserMessage)")
        }
        await refresh()
        await loadContext()
    }

    /// The count an "Empty Folder…" confirmation shows — minted before asking, so the count
    /// confirmed and the set deleted are the same snapshot.
    public func prepareEmptyFolder() async -> SelectionSnapshotResponse? {
        guard case .folder(let accountId, let folderId) = scope else { return nil }
        if let refusal = ledger.folderDestructionRefusal(accountId: accountId) {
            showError(refusal.userMessage)
            return nil
        }
        do {
            return try await backend.fetchSelectionSnapshot(accountId: accountId, folderId: folderId, filter: .all)
        } catch {
            showError("Could not count messages: \(error.mvUserMessage)")
            return nil
        }
    }

    public func emptyFolder(confirmed snapshot: SelectionSnapshotResponse) async {
        guard case .folder(let accountId, let folderId) = scope else { return }
        if let refusal = ledger.folderDestructionRefusal(accountId: accountId) {
            showError(refusal.userMessage)
            return
        }
        do {
            _ = try await backend.sendBulkAction(
                accountId: accountId,
                request: BulkActionRequest(
                    action: .expunge,
                    scope: BulkActionScope(folderId: folderId, filter: "all", snapshotAt: snapshot.snapshotAt),
                    confirmMessageCount: snapshot.count
                )
            )
        } catch {
            showError(error.mvUserMessage)
        }
        await replaceList()
        await loadContext()
    }

    // MARK: - Toasts and errors

    private func showError(_ message: String) {
        toasts?.show(MVToast(variant: .error, message: message, duration: 0))
    }

    static func isNotFound(_ error: Error) -> Bool {
        switch error as? MVError {
        case .detail(_, let statusCode)?: return statusCode == 404
        case .http(let statusCode, _)?: return statusCode == 404
        default: return false
        }
    }
}

extension MVMailListStore: ReaderConversationScopedSource {
    /// Grouped by conversation, a row stands for its whole conversation within this list's
    /// folders; ungrouped, a row is one message.
    public func conversationFolderIds(for messageId: UUID) -> [UUID]? {
        identity.threaded ? scopeFolderIds : nil
    }
}

extension MessageSummary {
    /// A search hit as a list row — the backend's `SearchResult` is `MessageSummary` plus how the
    /// query matched, which the quick filter does not show.
    public init(_ result: SearchResult) {
        self.init(
            id: result.id, accountId: result.accountId, folderId: result.folderId, threadId: result.threadId,
            subject: result.subject, fromAddr: result.fromAddr, toAddrs: result.toAddrs,
            receivedAt: result.receivedAt, isSeen: result.isSeen, isFlagged: result.isFlagged,
            isAnswered: result.isAnswered, isDraft: result.isDraft, snippet: result.snippet,
            pendingSync: result.pendingSync, isTruncated: result.isTruncated, threadCount: result.threadCount,
            unreadInThread: result.unreadInThread, mirroredAt: result.mirroredAt,
            hasAttachments: result.hasAttachments, verdictIsSpam: result.verdictIsSpam
        )
    }

    func with(
        isSeen: Bool? = nil, isFlagged: Bool? = nil, unreadInThread: Int?? = nil, folderId: UUID? = nil
    ) -> MessageSummary {
        MessageSummary(
            id: id, accountId: accountId, folderId: folderId ?? self.folderId, threadId: threadId, subject: subject,
            fromAddr: fromAddr, toAddrs: toAddrs, receivedAt: receivedAt, isSeen: isSeen ?? self.isSeen,
            isFlagged: isFlagged ?? self.isFlagged, isAnswered: isAnswered, isDraft: isDraft, snippet: snippet,
            pendingSync: pendingSync, isTruncated: isTruncated, threadCount: threadCount,
            unreadInThread: unreadInThread ?? self.unreadInThread, mirroredAt: mirroredAt,
            hasAttachments: hasAttachments, verdictIsSpam: verdictIsSpam
        )
    }
}
