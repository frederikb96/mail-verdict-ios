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

    public var anchorId: String { "folder:\(id)" }
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
    private let uiState: MailboxesUIState
    private let diskCache: MailboxesDiskCache
    /// The same `UserDefaults`-backed record `MVMessagePlaceResolver` reads `lastViewWasUnified`
    /// from — sharing it rather than each holding its own copy is what makes `recordViewed(_:)`
    /// actually feed the resolver's own next lookup.
    private let recentViews: MVRecentViewRecord
    private var syncPollingTask: Task<Void, Never>?
    private var liveSubscriptionToken: MVSubscriptionToken?

    public init(
        apiClient: MVApiClient, uiState: MailboxesUIState = MailboxesUIState(),
        diskCache: MailboxesDiskCache = MailboxesDiskCache(), recentViews: MVRecentViewRecord = MVRecentViewRecord(),
        membership: MailboxesUnifiedMembership = MailboxesUnifiedMembership()
    ) {
        self.apiClient = apiClient
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

    public func load() async {
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

            accountSections = try await loadAccountSections(accounts: accountList)
            saveSnapshotToDiskCache()
        } catch {
            loadError = error.mvUserMessage
        }
        isLoading = false
        reportDebugState()
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
            let order = try? await apiClient.getFolderOrder(accountId: account.id)
            let ordered = MailboxesSupport.orderFolders(
                order?.folders ?? [], hasCustomOrder: !(account.folderOrder ?? []).isEmpty)
            folders = ordered.map { item in
                MailboxesFolderRow(
                    id: item.folderId, accountId: account.id,
                    displayName: folderDisplayName(
                        imapName: item.imapName, displayName: item.displayName, specialUse: item.specialUse
                    ), specialUse: item.specialUse,
                    badgeCount: MailboxesSupport.folderBadgeCount(
                        specialUse: item.specialUse, unreadCount: item.unreadCount, totalCount: item.totalCount
                    ), totalCount: item.totalCount
                )
            }
        }

        return MailboxesAccountSection(
            id: account.id, name: account.name, emoji: account.emoji, connectionState: connectionState,
            stateError: account.stateError, folders: folders
        )
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
        try await apiClient.mintSelection(accountId: accountId, folderId: folderId, filter: "all")
    }

    @discardableResult
    public func emptyFolder(
        accountId: UUID, folderId: UUID, confirmMessageCount: Int, snapshotAt: Date
    ) async throws -> BulkActionResponse {
        let scope = BulkActionScope(folderId: folderId, filter: "all", snapshotAt: snapshotAt)
        let response = try await apiClient.bulkAction(
            accountId: accountId,
            request: BulkActionRequest(action: .expunge, scope: scope, confirmMessageCount: confirmMessageCount)
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
                        specialUse: $0.specialUse, badgeCount: $0.badgeCount, totalCount: $0.totalCount
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
                            badgeCount: $0.badgeCount, totalCount: $0.totalCount
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
        guard MailboxesSupport.shouldReload(for: invalidations) else { return }
        Task { await self.load() }
    }
}
