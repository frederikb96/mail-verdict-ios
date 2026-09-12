import Foundation
import Observation

/// One message list — a folder or a unified view. Owns the fetch window (a page around wherever
/// the list opened, older and newer pages on demand, one bounded request to refresh all of it),
/// the unread and quick filters, selection, and optimistic actions with Undo.
///
/// Scroll position is not here: the list controller owns the viewport and corrects it by the
/// anchor delta (`MVListAnchoring`) on every change this store makes to `rows`. `identity`
/// tells it when `rows` became a different list rather than the same list changed.
@Observable
@MainActor
public final class MVMailListStore: ReaderListSource, LiveEventSubscriber {

    public let scope: ListScope
    /// The toggle as the person set it. `identity.threaded` is what the loaded rows were
    /// fetched with — the two differ only while a toggle's first page is in flight.
    public private(set) var threaded: Bool
    public private(set) var unreadOnly: Bool
    public private(set) var identity: MVListIdentity
    public private(set) var rows: [MessageSummary] = []
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
    /// Bumped by every optimistic change. A refresh that was in flight across one is discarded
    /// and read again, so a stale response never puts back a row the reader just archived.
    @ObservationIgnored private var mutationEpoch = 0
    @ObservationIgnored private var filterDebounce: Task<Void, Never>?
    @ObservationIgnored private var unfiltered:
        (rows: [MessageSummary], hasOlder: Bool, hasNewer: Bool, identity: MVListIdentity)?
    @ObservationIgnored private var hasStarted = false
    @ObservationIgnored private var wasConnected: Bool?

    public static let filterMinimumLength = 2
    static let filterDebounceNanos: UInt64 = 150_000_000

    public init(
        scope: ListScope, aroundMessageId: UUID? = nil, backend: any MVMailListBackend, toasts: MVToastStore?,
        defaults: UserDefaults = .standard, session: MVListSession? = nil
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
        self.toasts = toasts
        self.defaults = defaults
        self.session = session
        self.positions = MVListPositionStore(defaults: defaults)
        self.initialAroundId = aroundMessageId
    }

    // MARK: - ReaderListSource

    public var rowIds: [UUID] { rows.map(\.id) }

    public func neighbours(of messageId: UUID) -> (older: UUID?, newer: UUID?) {
        guard let index = rows.firstIndex(where: { $0.id == messageId }) else { return (nil, nil) }
        let older = index + 1 < rows.count ? rows[index + 1].id : nil
        let newer = index > 0 ? rows[index - 1].id : nil
        return (older, newer)
    }

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
            rows = page.messages
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
                phase = .failed(Self.message(for: error))
            } else {
                showError("Could not load messages: \(Self.message(for: error))")
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
                    unreadOnly: started.unreadOnly, before: rows.last?.id, limit: MVMailListWindow.pageSize
                )
                guard identity == started else { return }
                rows = MVMailListWindow.appendingOlder(response.results.map(MessageSummary.init), to: rows)
                hasOlder = response.hasMore
                return
            }
            switch direction {
            case .older:
                guard let last = rows.last else { return }
                let response = try await backend.fetchListPage(
                    scope: scope, threaded: started.threaded, unreadOnly: started.unreadOnly,
                    cursor: .olderThan(last.id), limit: MVMailListWindow.pageSize
                )
                guard identity == started else { return }
                rows = MVMailListWindow.appendingOlder(response.messages, to: rows)
                hasOlder = response.hasMore
            case .newer:
                guard let first = rows.first else { return }
                let response = try await backend.fetchListPage(
                    scope: scope, threaded: started.threaded, unreadOnly: started.unreadOnly,
                    cursor: .newerThan(first.id), limit: MVMailListWindow.pageSize
                )
                guard identity == started else { return }
                rows = MVMailListWindow.prependingNewer(response.messages, to: rows)
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
        guard let first = rows.first,
            let response = try? await backend.fetchListPage(
                scope: scope, threaded: started.threaded, unreadOnly: started.unreadOnly,
                cursor: .newerThan(first.id), limit: MVMailListWindow.pageSize
            ),
            identity == started
        else { return }
        rows = MVMailListWindow.prependingNewer(response.messages, to: rows)
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
        guard phase == .loaded, !isFilterActive, !rows.isEmpty else { return }
        let started = identity
        let epoch = mutationEpoch
        let preserve = started.unreadOnly ? keptWhileUnread : []
        let limit = MVMailListWindow.refreshLimit(loadedRows: rows.count)
        do {
            if hasNewer {
                guard let last = rows.last else { return }
                let response = try await backend.fetchListPage(
                    scope: scope, threaded: started.threaded, unreadOnly: started.unreadOnly,
                    cursor: .newerThan(last.id), limit: limit
                )
                guard identity == started else { return }
                guard mutationEpoch == epoch else {
                    refreshAgain = true
                    return
                }
                let merged = MVMailListWindow.mergeRefreshedFromBelow(
                    current: rows, freshAboveLast: response.messages, freshHasMoreNewer: response.hasMoreNewer,
                    preserveIds: preserve
                )
                rows = merged.rows
                hasNewer = merged.hasNewer
            } else {
                let response = try await backend.fetchListPage(
                    scope: scope, threaded: started.threaded, unreadOnly: started.unreadOnly, cursor: .newest,
                    limit: limit
                )
                guard identity == started else { return }
                guard mutationEpoch == epoch else {
                    refreshAgain = true
                    return
                }
                let merged = MVMailListWindow.mergeRefreshed(
                    current: rows, fresh: response.messages, freshHasMore: response.hasMore,
                    currentHasMore: hasOlder, preserveIds: preserve
                )
                rows = merged.rows
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

    private func loadContext() async {
        var next = context
        if let accounts = try? await backend.fetchAccounts() {
            next.accounts = Dictionary(accounts.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        }
        switch scope {
        case .folder(let accountId, _):
            if let folders = try? await backend.fetchFolders(accountId: accountId) {
                next.folders = Dictionary(folders.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            }
            next.neverConnectedError = nil
            if let account = next.accounts[accountId], account.state == "error",
                let status = try? await backend.fetchSyncStatus(accountId: accountId), status.lastFullSync == nil
            {
                next.neverConnectedError = account.stateError ?? "This account has never connected"
            }
        case .unified(let viewId, _):
            if let views = try? await backend.fetchUnifiedViews() {
                next.unifiedView = views.first { $0.id == viewId }
            }
            var folders: [UUID: FolderResponse] = [:]
            for accountId in Set(next.unifiedView?.folders.map(\.accountId) ?? []) {
                for folder in (try? await backend.fetchFolders(accountId: accountId)) ?? [] {
                    folders[folder.id] = folder
                }
            }
            next.folders = folders
        }
        if let dead = try? await backend.fetchDeadOutbox() {
            let accountIds = Set(accountIdsIn(next))
            let scoped = dead.filter { accountIds.contains($0.accountId) }
            next.deadOutboxCount = scoped.count
            next.deadOutboxAccountNames = Set(scoped.map(\.accountId)).compactMap { next.accounts[$0]?.name }.sorted()
        }
        var photos: [String: MVAvatarPhotoSource] = [:]
        for accountId in accountIdsIn(next) {
            guard let index = try? await backend.fetchContactPhotoIndex(accountId: accountId) else { continue }
            for (email, entry) in index.byEmail { photos[email.lowercased()] = entry.avatarSource }
        }
        next.avatarPhotos = photos
        context = next
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
                    mutationEpoch += 1
                    rows.removeAll { $0.id == messageId }
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
        guard query != identity.filterQuery else { return }
        if query.isEmpty {
            isFilterLoading = false
            guard let saved = unfiltered else { return }
            unfiltered = nil
            rows = saved.rows
            hasOlder = saved.hasOlder
            hasNewer = saved.hasNewer
            identity = saved.identity
            phase = .loaded
            requestRefresh()
            return
        }
        let folderIds = filterFolderIds
        guard !folderIds.isEmpty, phase == .loaded || unfiltered != nil else { return }
        if unfiltered == nil { unfiltered = (rows, hasOlder, hasNewer, identity) }
        generation += 1
        let started = MVListIdentity(
            scope: scope, threaded: identity.threaded, unreadOnly: unreadOnly, filterQuery: query,
            generation: generation
        )
        selection = .empty
        isFilterLoading = true
        do {
            let response = try await backend.fetchFilterPage(
                query: query, accountId: filterAccountId, folderIds: folderIds, unreadOnly: unreadOnly, before: nil,
                limit: MVMailListWindow.pageSize
            )
            guard generation == started.generation else { return }
            identity = started
            rows = response.results.map(MessageSummary.init)
            hasOlder = response.hasMore
            hasNewer = false
            phase = .loaded
        } catch {
            guard generation == started.generation else { return }
            showError("Could not filter: \(Self.message(for: error))")
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
            isStarred: row.isFlagged, snippet: row.snippet,
            avatarIdentity: row.fromAddr.map(extractEmail) ?? extractSenderName(row.fromAddr),
            avatarPhoto: context.avatarPhotos[extractEmail(row.fromAddr).lowercased()],
            unifiedAccountEmoji: isUnified ? context.accounts[row.accountId]?.emoji : nil
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
        guard let bulk = MailActionService.bulkAction(for: action, targetFolderId: targetFolderId),
            let wire = MVMessageAction(rawValue: bulk.rawValue)
        else { return }

        mutationEpoch += 1
        if bulk.removesFromList {
            rows.removeAll { $0.id == rowId }
        } else {
            rows = rows.map { $0.id == rowId ? Self.applying(bulk, to: $0, threaded: identity.threaded) : $0 }
        }
        if bulk == .markRead { keptWhileUnread.insert(rowId) }
        if bulk == .markUnread { Task { await MVExplicitUnreadTracker.shared.markExplicit(rowId) } }

        Task { [weak self] in
            guard let self else { return }
            do {
                try await self.backend.sendMessageAction(messageId: rowId, action: wire, targetFolderId: targetFolderId)
                if let title = bulk.undoToastTitle {
                    self.showUndo(title) { [weak self] in
                        await self?.undoSingleMove(messageId: rowId, originalFolderId: row.folderId)
                    }
                }
            } catch {
                self.rollBack([row])
                self.showError("Could not \(bulk.phrase): \(Self.message(for: error))")
            }
            self.requestRefresh()
        }
    }

    private func undoSingleMove(messageId: UUID, originalFolderId: UUID) async {
        do {
            try await backend.sendMessageAction(messageId: messageId, action: .move, targetFolderId: originalFolderId)
        } catch {
            showError("Could not undo: \(Self.message(for: error))")
        }
        await refresh()
    }

    /// Reading a conversation row clears every unread message it counts, not only the newest one
    /// it stands for (port of the web's `useMarkConversationRead`).
    private func markConversationRead(_ row: MessageSummary) {
        mutationEpoch += 1
        rows = rows.map { $0.id == row.id ? $0.with(isSeen: true, unreadInThread: 0) : $0 }
        keptWhileUnread.insert(row.id)
        let inScope = Set(scopeFolderIds)
        Task { [weak self] in
            guard let self else { return }
            do {
                let thread = try await self.backend.fetchThread(messageId: row.id)
                let ids = thread.messages.filter { inScope.contains($0.folderId) && !$0.isSeen }.map(\.id)
                self.keptWhileUnread.formUnion(ids)
                if !ids.isEmpty {
                    _ = try await self.backend.sendBulkAction(
                        accountId: row.accountId, request: BulkActionRequest(action: .markRead, ids: ids)
                    )
                }
            } catch {
                self.rollBack([row])
                self.showError("Could not mark as read: \(Self.message(for: error))")
            }
            self.requestRefresh()
        }
    }

    private func sendVerdictFeedback(_ row: MessageSummary, isSpam: Bool) {
        Task { [weak self] in
            guard let self else { return }
            do {
                try await self.backend.sendVerdictFeedback(messageId: row.id, accountId: row.accountId, isSpam: isSpam)
                self.toasts?.show(MVToast(variant: .success, message: "Thanks — feedback recorded", duration: 3))
            } catch {
                self.showError("Could not send feedback: \(Self.message(for: error))")
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

    static func applying(_ action: MVBulkAction, to row: MessageSummary, threaded: Bool) -> MessageSummary {
        switch action {
        case .markRead:
            let unread = threaded ? max((row.unreadInThread ?? 0) - (row.isSeen ? 0 : 1), 0) : row.unreadInThread
            return row.with(isSeen: true, unreadInThread: unread)
        case .markUnread:
            let unread = threaded ? (row.unreadInThread ?? 0) + (row.isSeen ? 1 : 0) : row.unreadInThread
            return row.with(isSeen: false, unreadInThread: unread)
        case .flag: return row.with(isFlagged: true)
        case .unflag: return row.with(isFlagged: false)
        default: return row
        }
    }

    /// Puts rows back as they were before an optimistic change that failed — a removed row back
    /// in its sorted place, a changed one back to its old values — without discarding anything
    /// else that changed meanwhile.
    private func rollBack(_ originals: [MessageSummary]) {
        var next = rows
        for original in originals {
            if let index = next.firstIndex(where: { $0.id == original.id }) {
                next[index] = original
            } else {
                let position = next.firstIndex { MVMailListWindow.sitsAbove(original, $0) } ?? next.count
                next.insert(original, at: position)
            }
        }
        rows = next
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
            showError("Could not select all: \(Self.message(for: error))")
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

        var originals: [MessageSummary] = []
        if current.predicate == nil {
            let ids = Set(current.included.keys)
            originals = rows.filter { ids.contains($0.id) }
            mutationEpoch += 1
            if action.removesFromList {
                rows.removeAll { ids.contains($0.id) }
            } else {
                rows = rows.map {
                    ids.contains($0.id) ? Self.applying(action, to: $0, threaded: identity.threaded) : $0
                }
            }
            if action == .markRead { keptWhileUnread.formUnion(ids) }
            if action == .markUnread {
                Task { for id in ids { await MVExplicitUnreadTracker.shared.markExplicit(id) } }
            }
        }
        selection = .empty
        isSelecting = false

        do {
            var sources: [MVMovedMessage] = []
            var affected = 0
            for plan in built.plans {
                let response = try await backend.sendBulkAction(accountId: plan.accountId, request: plan.request)
                guard response.success else {
                    throw MVError.detail(
                        response.errors.joined(separator: "; ").isEmpty
                            ? "Could not \(action.phrase)" : response.errors.joined(separator: "; "),
                        statusCode: 200
                    )
                }
                affected += response.affectedCount
                sources += response.sources.map {
                    MVMovedMessage(messageId: $0.id, accountId: plan.accountId, originalFolderId: $0.folderId)
                }
            }
            if current.predicate == nil, let phrase = action.bulkUndoPhrase {
                // A conversation row stood for messages no row ever showed; the server's
                // `sources` name every one of them when it expanded threads.
                let moved =
                    sources.isEmpty
                    ? originals.map {
                        MVMovedMessage(messageId: $0.id, accountId: $0.accountId, originalFolderId: $0.folderId)
                    } : sources
                let requested = moved.count
                let partial = affected < requested
                let noun = requested == 1 ? "message" : "messages"
                let message =
                    partial ? "\(affected) of \(requested) \(noun) \(phrase)" : "\(requested) \(noun) \(phrase)"
                showUndo(message, variant: partial ? .warning : .success) { [weak self] in
                    await self?.undoBulkMove(moved)
                }
            }
            if !built.skippedAccountIds.isEmpty {
                toasts?.show(
                    MVToast(
                        variant: .warning,
                        message: "Some messages were not moved — the destination does not exist in every account",
                        duration: 6
                    )
                )
            }
        } catch {
            rollBack(originals)
            showError("Could not \(action.phrase): \(Self.message(for: error))")
        }

        if current.predicate != nil {
            await replaceList()
        } else {
            requestRefresh()
        }
    }

    private func undoBulkMove(_ moved: [MVMovedMessage]) async {
        do {
            for plan in MVBulkRequestBuilder.undoPlans(for: moved) {
                _ = try await backend.sendBulkAction(accountId: plan.accountId, request: plan.request)
            }
        } catch {
            showError("Could not undo: \(Self.message(for: error))")
        }
        await refresh()
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
            showError("Could not mark as read: \(Self.message(for: error))")
        }
        await refresh()
        await loadContext()
    }

    /// The count an "Empty Folder…" confirmation shows — minted before asking, so the count
    /// confirmed and the set deleted are the same snapshot.
    public func prepareEmptyFolder() async -> SelectionSnapshotResponse? {
        guard case .folder(let accountId, let folderId) = scope else { return nil }
        do {
            return try await backend.fetchSelectionSnapshot(accountId: accountId, folderId: folderId, filter: .all)
        } catch {
            showError("Could not count messages: \(Self.message(for: error))")
            return nil
        }
    }

    public func emptyFolder(confirmed snapshot: SelectionSnapshotResponse) async {
        guard case .folder(let accountId, let folderId) = scope else { return }
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
            showError(Self.message(for: error))
        }
        await replaceList()
        await loadContext()
    }

    // MARK: - Toasts and errors

    private func showUndo(
        _ message: String, variant: MVToastVariant = .success, undo: @escaping @Sendable @MainActor () async -> Void
    ) {
        toasts?.show(
            MVToast(
                variant: variant, message: message, duration: 6, actionTitle: "Undo",
                action: { Task { @MainActor in await undo() } }
            )
        )
    }

    private func showError(_ message: String) {
        toasts?.show(MVToast(variant: .error, message: message, duration: 0))
    }

    static func message(for error: Error) -> String {
        (error as? MVError)?.userMessage ?? error.localizedDescription
    }

    static func isNotFound(_ error: Error) -> Bool {
        switch error as? MVError {
        case .detail(_, let statusCode)?: return statusCode == 404
        case .http(let statusCode, _)?: return statusCode == 404
        default: return false
        }
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

    func with(isSeen: Bool? = nil, isFlagged: Bool? = nil, unreadInThread: Int?? = nil) -> MessageSummary {
        MessageSummary(
            id: id, accountId: accountId, folderId: folderId, threadId: threadId, subject: subject,
            fromAddr: fromAddr, toAddrs: toAddrs, receivedAt: receivedAt, isSeen: isSeen ?? self.isSeen,
            isFlagged: isFlagged ?? self.isFlagged, isAnswered: isAnswered, isDraft: isDraft, snippet: snippet,
            pendingSync: pendingSync, isTruncated: isTruncated, threadCount: threadCount,
            unreadInThread: unreadInThread ?? self.unreadInThread, mirroredAt: mirroredAt,
            hasAttachments: hasAttachments, verdictIsSpam: verdictIsSpam
        )
    }
}
