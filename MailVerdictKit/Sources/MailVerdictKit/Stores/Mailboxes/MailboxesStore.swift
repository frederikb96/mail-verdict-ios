import Foundation
import Observation

/// A folder or a unified view — one type so `recordViewed(_:)` below takes a single shape
/// regardless of which kind of row was tapped.
public enum MailboxesRowKind: Sendable, Equatable {
    case folder(accountId: UUID, folderId: UUID)
    case unified(viewId: UUID, name: String)
}

public struct MailboxesFolderRow: Identifiable, Sendable, Equatable {
    public let id: UUID
    public let accountId: UUID
    public let displayName: String
    public let specialUse: String?
    public let badgeCount: Int
    /// The folder's real message count — distinct from `badgeCount` (which is the unread count,
    /// or the total for Drafts): Empty/Delete Folder's confirm text always names the total,
    /// regardless of what the badge happens to be showing.
    public let totalCount: Int
    /// "glacier" for the one synthetic per-account row; every real IMAP folder is "imap".
    public let kind: String

    public var isGlacier: Bool { kind == "glacier" }

    public var anchorId: String { "folder:\(id)" }

    public init(
        id: UUID, accountId: UUID, displayName: String, specialUse: String?, badgeCount: Int,
        totalCount: Int, kind: String = "imap"
    ) {
        self.id = id
        self.accountId = accountId
        self.displayName = displayName
        self.specialUse = specialUse
        self.badgeCount = badgeCount
        self.totalCount = totalCount
        self.kind = kind
    }
}

public struct MailboxesAccountSection: Identifiable, Sendable, Equatable {
    public let id: UUID
    public let name: String
    public let emoji: String?
    public let connectionState: MVAccountConnectionState
    public let stateError: String?
    public let folders: [MailboxesFolderRow]

    public var collapseKey: String { MailboxesUIState.accountKey(id) }
}

public struct MailboxesUnifiedRow: Identifiable, Sendable, Equatable {
    public let id: UUID
    public let name: String
    public let emoji: String?
    public let unreadCount: Int
    public let contributingAccountEmojis: [String]

    public var anchorId: String { "unified:\(id)" }
}

/// Everything the Mailboxes screen (overview) needs: unified views plus one collapsible section
/// per account, the dead-outbox banner, the bell badge, and scroll/collapse restoration across
/// relaunch. `membership` is what `MVMessagePlaceResolver` takes as its
/// `MVUnifiedViewMembershipLookup` — see that type's own doc comment for why it is not this class
/// itself.
@Observable
@MainActor
public final class MailboxesStore {
    public private(set) var unifiedRows: [MailboxesUnifiedRow] = []
    public private(set) var accountSections: [MailboxesAccountSection] = []
    public private(set) var deadOutboxBannerText: String?
    public private(set) var bellBadgeCount: Int = 0
    public private(set) var isLoading = false
    public private(set) var loadError: String?
    public private(set) var hasAnyAccount = true
    /// Which sections are collapsed — the `@Observable`-tracked mirror of `uiState`'s own
    /// `UserDefaults` storage. `MailboxesScreen`'s body reads this (through `isCollapsed(_:)`),
    /// never `uiState` directly, so `toggleCollapsed` actually triggers a re-render.
    public private(set) var collapsedKeys: Set<String>

    public let membership: MailboxesUnifiedMembership

    private let apiClient: MVApiClient
    private let ledger: MVIntentLedger
    private let uiState: MailboxesUIState
    private let diskCache: MailboxesDiskCache
    /// The same `UserDefaults`-backed record `MVMessagePlaceResolver` reads `lastViewWasUnified`
    /// from — sharing it rather than each holding its own copy is what makes `recordViewed(_:)`
    /// actually feed the resolver's own next lookup.
    private let recentViews: MVRecentViewRecord
    private var syncPollingTask: Task<Void, Never>?
    private var liveSubscriptionToken: MVSubscriptionToken?
    /// The one reload running, and what arrived meanwhile: merged into a single follow-up.
    private var reloadTask: Task<Void, Never>?
    private var queuedPlan: MailboxesReloadPlan?
    /// Whether each account has a saved folder order, as the last full load read it. A folder
    /// list is ordered differently with one (`MailboxesSupport.orderFolders`), and `/folder-order`
    /// does not say.
    private var hasCustomFolderOrder: [UUID: Bool] = [:]

    public init(
        apiClient: MVApiClient, ledger: MVIntentLedger, uiState: MailboxesUIState = MailboxesUIState(),
        diskCache: MailboxesDiskCache = MailboxesDiskCache(), recentViews: MVRecentViewRecord = MVRecentViewRecord(),
        membership: MailboxesUnifiedMembership = MailboxesUnifiedMembership()
    ) {
        self.apiClient = apiClient
        self.ledger = ledger
        self.uiState = uiState
        self.diskCache = diskCache
        self.recentViews = recentViews
        self.membership = membership
        self.collapsedKeys = uiState.collapsedKeys()
        applyCachedSnapshotIfAvailable()
    }

    // MARK: - Collapse state

    public func isCollapsed(_ key: String) -> Bool { collapsedKeys.contains(key) }

    public func toggleCollapsed(_ key: String) {
        let collapsed = !collapsedKeys.contains(key)
        if collapsed { collapsedKeys.insert(key) } else { collapsedKeys.remove(key) }
        uiState.setCollapsed(collapsed, forKey: key)
        reportDebugState()
    }

    // MARK: - Scroll anchor

    public var topVisibleRowId: String? {
        get { uiState.topVisibleRowId() }
        set {
            uiState.setTopVisibleRowId(newValue)
            reportDebugState()
        }
    }

    /// `/mailboxes/state`'s own data — reported here, on the main actor, rather than read
    /// directly from that route's synchronous, non-isolated handler.
    private func reportDebugState() {
        #if DEBUG
            MailboxesDebugReporter.shared.report(
                MVMailboxesDebugSnapshot(
                    unifiedCollapsed: isCollapsed(MailboxesUIState.unifiedKey()),
                    accountCollapsed: accountSections.map { isCollapsed($0.collapseKey) },
                    topVisibleRowId: topVisibleRowId ?? "", unifiedRowCount: unifiedRows.count,
                    accountSectionCount: accountSections.count, bellBadgeCount: bellBadgeCount,
                    hasDeadOutboxBanner: deadOutboxBannerText != nil
                )
            )
        #endif
    }

    // MARK: - Loading

    /// Reads everything. Joins a reload that is already running instead of starting a second.
    public func load() async {
        await reload(.all)
    }

    /// Runs `plan` after any reload in progress, merged with whatever else queued meanwhile — one
    /// running and at most one waiting, however many events arrive during a sync.
    private func reload(_ plan: MailboxesReloadPlan) async {
        if let running = reloadTask {
            var merged = queuedPlan ?? MailboxesReloadPlan()
            merged.merge(plan)
            queuedPlan = merged
            await running.value
            return
        }
        queuedPlan = plan
        let task = Task { [weak self] in
            while let self, let next = self.queuedPlan {
                self.queuedPlan = nil
                await self.perform(next)
            }
            self?.reloadTask = nil
        }
        reloadTask = task
        await task.value
    }

    private func perform(_ plan: MailboxesReloadPlan) async {
        if plan.everything {
            await loadEverything()
            return
        }
        async let countsApplied = plan.counts ? reloadCounts(plan) : true
        async let badge: Void = plan.badge ? reloadBadge() : ()
        async let deadOutbox: Void = plan.deadOutbox ? reloadDeadOutbox() : ()
        let applied = await countsApplied
        await badge
        await deadOutbox
        // Counts for a screen not fully loaded yet, or an account it does not show, need the rest.
        if !applied { await loadEverything() }
        saveSnapshotToDiskCache()
        reportDebugState()
    }

    private func loadEverything() async {
        isLoading = unifiedRows.isEmpty && accountSections.isEmpty
        loadError = nil
        do {
            async let accounts = apiClient.listAccounts()
            async let unified = apiClient.listUnifiedFolders()
            async let deadOutbox = apiClient.listOutbox(status: "dead")
            async let badge = apiClient.getAlertBadge(folderIds: nil)

            let (accountList, unifiedList, deadList, badgeResponse) =
                try await (accounts, unified, deadOutbox, badge)

            hasAnyAccount = !accountList.isEmpty
            membership.update(from: unifiedList)
            bellBadgeCount = badgeResponse.count

            let accountNames = MailboxesSupport.distinctAccountNames(
                forAccountIds: deadList.map(\.accountId), accounts: accountList
            )
            deadOutboxBannerText = MailboxesSupport.deadOutboxBannerText(
                messageCount: deadList.count, accountNames: accountNames
            )

            unifiedRows = unifiedList.map { view in
                MailboxesUnifiedRow(
                    id: view.id, name: view.unifiedName, emoji: view.emoji,
                    unreadCount: view.unreadCount,
                    contributingAccountEmojis: MailboxesSupport.contributingAccounts(
                        for: view, accounts: accountList
                    ).map { $0.emoji ?? "✉️" }
                )
            }

            for account in accountList { noteFolderOrder(of: account) }
            accountSections = try await loadAccountSections(accounts: accountList)
            saveSnapshotToDiskCache()
        } catch {
            loadError = error.mvUserMessage
        }
        isLoading = false
        reportDebugState()
    }

    private func noteFolderOrder(of account: AccountResponse) {
        hasCustomFolderOrder[account.id] = !(account.folderOrder ?? []).isEmpty
    }

    /// Re-reads the unified rows and the folder rows of the accounts the plan names: the counts a
    /// mail event can have changed. `false` when that cannot be done from what is already on
    /// screen, and a full load is needed instead.
    private func reloadCounts(_ plan: MailboxesReloadPlan) async -> Bool {
        let shown = Set(accountSections.map(\.id))
        let accountIds = plan.countsForAllAccounts ? shown : plan.countAccountIds
        guard !shown.isEmpty, accountIds.isSubset(of: shown),
            accountIds.allSatisfy({ hasCustomFolderOrder[$0] != nil })
        else { return false }

        async let unified = try? apiClient.listUnifiedFolders()
        let rows = await Self.folderRows(
            ofAccounts: accountIds.filter { id in
                accountSections.first { $0.id == id }?.connectionState != .neverConnected
            }, hasCustomOrder: hasCustomFolderOrder, apiClient: apiClient)

        var sections = accountSections
        for index in sections.indices {
            guard let folders = rows[sections[index].id] else { continue }
            let section = sections[index]
            sections[index] = MailboxesAccountSection(
                id: section.id, name: section.name, emoji: section.emoji,
                connectionState: section.connectionState, stateError: section.stateError, folders: folders
            )
        }
        if sections != accountSections { accountSections = sections }

        guard let unifiedList = await unified else { return true }
        // A view added or removed changes more than a count.
        guard Set(unifiedList.map(\.id)) == Set(unifiedRows.map(\.id)) else { return false }
        membership.update(from: unifiedList)
        let previous = Dictionary(uniqueKeysWithValues: unifiedRows.map { ($0.id, $0) })
        let updated = unifiedList.map { view in
            MailboxesUnifiedRow(
                id: view.id, name: view.unifiedName, emoji: view.emoji, unreadCount: view.unreadCount,
                contributingAccountEmojis: previous[view.id]?.contributingAccountEmojis ?? []
            )
        }
        if updated != unifiedRows { unifiedRows = updated }
        return true
    }

    private func reloadBadge() async {
        guard let badge = try? await apiClient.getAlertBadge(folderIds: nil) else { return }
        if badge.count != bellBadgeCount { bellBadgeCount = badge.count }
    }

    private func reloadDeadOutbox() async {
        guard let dead = try? await apiClient.listOutbox(status: "dead") else { return }
        let names = MailboxesSupport.distinctAccountNames(forAccountIds: dead.map(\.accountId)) { id in
            accountSections.first { $0.id == id }?.name
        }
        let text = MailboxesSupport.deadOutboxBannerText(messageCount: dead.count, accountNames: names)
        if text != deadOutboxBannerText { deadOutboxBannerText = text }
    }

    private func loadAccountSections(accounts: [AccountResponse]) async throws -> [MailboxesAccountSection] {
        try await withThrowingTaskGroup(of: (Int, MailboxesAccountSection).self) { group in
            for (index, account) in accounts.enumerated() {
                group.addTask { [apiClient] in
                    let section = await Self.buildSection(for: account, apiClient: apiClient)
                    return (index, section)
                }
            }
            var sections = [MailboxesAccountSection?](repeating: nil, count: accounts.count)
            for try await (index, section) in group {
                sections[index] = section
            }
            return sections.compactMap { $0 }
        }
    }

    /// `static`, capturing nothing but its arguments, so each account's fetch is independent —
    /// one account's folder-order failure never blocks another's section from rendering.
    private static func buildSection(
        for account: AccountResponse, apiClient: MVApiClient
    ) async -> MailboxesAccountSection {
        let syncStatus = try? await apiClient.getSyncStatus(accountId: account.id)
        let connectionState = MVAccountConnectionState.classify(
            state: account.state, lastFullSync: syncStatus?.lastFullSync != nil
        )

        var folders: [MailboxesFolderRow] = []
        if connectionState != .neverConnected {
            folders =
                await folderRows(
                    accountId: account.id, hasCustomOrder: !(account.folderOrder ?? []).isEmpty,
                    apiClient: apiClient) ?? []
        }

        return MailboxesAccountSection(
            id: account.id, name: account.name, emoji: account.emoji, connectionState: connectionState,
            stateError: account.stateError, folders: folders
        )
    }

    /// An account's folder rows in display order; `nil` when `/folder-order` could not be read.
    private static func folderRows(
        accountId: UUID, hasCustomOrder: Bool, apiClient: MVApiClient
    ) async -> [MailboxesFolderRow]? {
        guard let order = try? await apiClient.getFolderOrder(accountId: accountId) else { return nil }
        return MailboxesSupport.orderFolders(order.folders, hasCustomOrder: hasCustomOrder).map { item in
            MailboxesFolderRow(
                id: item.folderId, accountId: accountId,
                displayName: folderDisplayName(
                    imapName: item.imapName, displayName: item.displayName, specialUse: item.specialUse
                ), specialUse: item.specialUse,
                badgeCount: MailboxesSupport.folderBadgeCount(
                    specialUse: item.specialUse, unreadCount: item.unreadCount, totalCount: item.totalCount
                ), totalCount: item.totalCount, kind: item.kind
            )
        }
    }

    /// Several accounts' folder rows at once, keyed by account; an account whose read failed is
    /// absent.
    private static func folderRows(
        ofAccounts accountIds: Set<UUID>, hasCustomOrder: [UUID: Bool],
        apiClient: MVApiClient
    ) async -> [UUID: [MailboxesFolderRow]] {
        await withTaskGroup(of: (UUID, [MailboxesFolderRow]?).self) { group in
            for accountId in accountIds {
                let custom = hasCustomOrder[accountId] ?? false
                group.addTask {
                    (accountId, await folderRows(accountId: accountId, hasCustomOrder: custom, apiClient: apiClient))
                }
            }
            var result: [UUID: [MailboxesFolderRow]] = [:]
            for await (accountId, rows) in group { if let rows { result[accountId] = rows } }
            return result
        }
    }

    // MARK: - Folder and account actions

    /// `POST .../bulk-action {action: mark_read, target: {scope: {folder_id, filter: all}}}` —
    /// the folder-menu and list-••• "Mark All as Read" call, identical either way.
    @discardableResult
    public func markAllAsRead(accountId: UUID, folderId: UUID) async throws -> BulkActionResponse {
        let scope = BulkActionScope(folderId: folderId, filter: "all", snapshotAt: Date())
        let response = try await apiClient.bulkAction(
            accountId: accountId, request: BulkActionRequest(action: .markRead, scope: scope)
        )
        await refreshAccountSection(accountId: accountId)
        return response
    }

    /// Mints the selection snapshot "Empty Folder…" needs to confirm a count against, before the
    /// destructive alert is ever shown.
    public func mintEmptySelection(accountId: UUID, folderId: UUID) async throws -> SelectionSnapshotResponse {
        if let refusal = ledger.folderDestructionRefusal(accountId: accountId) { throw refusal }
        return try await apiClient.mintSelection(accountId: accountId, folderId: folderId, filter: "all")
    }

    /// Why a folder of this account may not be emptied or deleted right now — the check the
    /// confirmation runs before it is shown, and the destructive call runs again.
    public func folderDestructionRefusal(accountId: UUID) -> MVError? {
        ledger.folderDestructionRefusal(accountId: accountId)
    }

    @discardableResult
    public func emptyFolder(
        accountId: UUID, folderId: UUID, confirmMessageCount: Int, snapshotAt: Date
    ) async throws -> BulkActionResponse {
        if let refusal = ledger.folderDestructionRefusal(accountId: accountId) { throw refusal }
        let scope = BulkActionScope(folderId: folderId, filter: "all", snapshotAt: snapshotAt)
        let response = try await apiClient.bulkAction(
            accountId: accountId,
            request: BulkActionRequest(
                action: .expunge, scope: scope,
                // Only ever read server-side for a permanent delete of the glacier's own
                // contents -- ignored everywhere else, and this request always reaches here from
                // the folder's own already-confirmed "Empty Folder…" alert.
                confirmMessageCount: confirmMessageCount, confirm: true
            )
        )
        await refreshAccountSection(accountId: accountId)
        return response
    }

    @discardableResult
    public func createFolder(accountId: UUID, name: String, parentId: UUID?) async throws -> FolderResponse {
        let response = try await apiClient.createFolder(
            accountId: accountId, FolderCreateRequest(name: name, parentId: parentId)
        )
        await refreshAccountSection(accountId: accountId)
        return response
    }

    public func deleteFolder(accountId: UUID, folderId: UUID, confirmMessageCount: Int) async throws {
        if let refusal = ledger.folderDestructionRefusal(accountId: accountId) { throw refusal }
        try await apiClient.deleteFolder(folderId: folderId, confirmMessageCount: confirmMessageCount)
        await refreshAccountSection(accountId: accountId)
    }

    public func triggerSync(accountId: UUID) async throws {
        try await apiClient.triggerSync(accountId: accountId)
        await refreshConnectionStates()
    }

    /// Refetches exactly one account's section — a folder create, delete or Mark-All-as-Read call
    /// only ever changes that one account, so reloading the whole screen for it would refetch
    /// every other account's folders and sync status for nothing.
    private func refreshAccountSection(accountId: UUID) async {
        guard let account = try? await apiClient.getAccount(id: accountId) else { return }
        noteFolderOrder(of: account)
        let section = await Self.buildSection(for: account, apiClient: apiClient)
        if let index = accountSections.firstIndex(where: { $0.id == accountId }) {
            accountSections[index] = section
        } else {
            accountSections.append(section)
        }
        saveSnapshotToDiskCache()
        reportDebugState()
    }

    // MARK: - Sync-status polling

    /// Polls account health every 30s while this screen is visible — called from the screen's
    /// own `.task`, cancelled from `.onDisappear`/task cancellation, never left
    /// running once the screen is off-screen.
    public func startSyncStatusPolling() {
        syncPollingTask?.cancel()
        syncPollingTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 30_000_000_000)
                guard !Task.isCancelled, let self else { return }
                await self.refreshConnectionStates()
            }
        }
    }

    public func stopSyncStatusPolling() {
        syncPollingTask?.cancel()
        syncPollingTask = nil
    }

    private func refreshConnectionStates() async {
        guard !accountSections.isEmpty else { return }
        var updated = accountSections
        for index in updated.indices {
            let section = updated[index]
            // `SyncStatusResponse.state` mirrors the account's own `state` — reading it here
            // avoids a second `getAccount` fetch just to learn what this poll already needs, and
            // a failed poll is dropped rather than trusted: it must never downgrade a healthy
            // section to "never connected" on a transient network hiccup.
            guard let syncStatus = try? await apiClient.getSyncStatus(accountId: section.id) else { continue }
            let state = MVAccountConnectionState.classify(
                state: syncStatus.state, lastFullSync: syncStatus.lastFullSync != nil
            )
            updated[index] = MailboxesAccountSection(
                id: section.id, name: section.name, emoji: section.emoji, connectionState: state,
                stateError: syncStatus.stateError ?? section.stateError, folders: section.folders
            )
        }
        // An unchanged poll must not reassign: every assignment re-renders the whole list, and a
        // re-render landing mid-touch can swallow a row tap.
        if updated != accountSections { accountSections = updated }
    }

    // MARK: - Disk cache

    private func applyCachedSnapshotIfAvailable() {
        guard let snapshot = diskCache.load() else { return }
        unifiedRows = snapshot.unified.map {
            MailboxesUnifiedRow(
                id: $0.id, name: $0.name, emoji: $0.emoji, unreadCount: $0.unreadCount,
                contributingAccountEmojis: $0.contributingAccountEmojis
            )
        }
        accountSections = snapshot.accounts.map { cached in
            MailboxesAccountSection(
                id: cached.id, name: cached.name, emoji: cached.emoji, connectionState: .ok,
                stateError: nil,
                folders: cached.folders.map {
                    MailboxesFolderRow(
                        id: $0.id, accountId: cached.id, displayName: $0.displayName,
                        specialUse: $0.specialUse, badgeCount: $0.badgeCount, totalCount: $0.totalCount,
                        kind: $0.kind
                    )
                }
            )
        }
    }

    private func saveSnapshotToDiskCache() {
        let snapshot = MVMailboxesCacheSnapshot(
            unified: unifiedRows.map {
                MVMailboxesCachedUnified(
                    id: $0.id, name: $0.name, emoji: $0.emoji, unreadCount: $0.unreadCount,
                    contributingAccountEmojis: $0.contributingAccountEmojis
                )
            },
            accounts: accountSections.map { section in
                MVMailboxesCachedAccount(
                    id: section.id, name: section.name, emoji: section.emoji,
                    folders: section.folders.map {
                        MVMailboxesCachedFolder(
                            id: $0.id, displayName: $0.displayName, specialUse: $0.specialUse,
                            badgeCount: $0.badgeCount, totalCount: $0.totalCount, kind: $0.kind
                        )
                    }
                )
            },
            savedAt: Date()
        )
        diskCache.save(snapshot)
    }

    // MARK: - Recording which kind of view was last opened

    /// Tapping a folder or unified row records whether the last view was unified, so a later
    /// deep link or notification tap opens in the same kind of view this screen was last showing.
    public func recordViewed(_ kind: MailboxesRowKind) {
        switch kind {
        case .folder:
            recentViews.recordFolderView()
        case .unified(let viewId, let name):
            recentViews.recordUnifiedView(MVUnifiedViewRef(id: viewId, name: name))
        }
    }

    // MARK: - Live updates

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

extension MailboxesStore: LiveEventSubscriber {
    public func apply(_ invalidations: [MVLiveInvalidation]) {
        let plan = MailboxesSupport.reloadPlan(for: invalidations) { folderId in
            self.accountSections.first { $0.folders.contains { $0.id == folderId } }?.id
        }
        guard !plan.isEmpty else { return }
        Task { await self.reload(plan) }
    }
}
