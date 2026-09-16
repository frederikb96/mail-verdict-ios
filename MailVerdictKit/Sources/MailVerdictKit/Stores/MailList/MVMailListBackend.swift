import Foundation

/// Where one list page starts.
public enum MVListCursor: Equatable, Sendable {
    /// The newest edge.
    case newest
    /// Continuing older, below this row.
    case olderThan(UUID)
    /// Continuing newer, above this row — only meaningful once a window opened away from the
    /// newest edge.
    case newerThan(UUID)
    /// A fresh page centred on this message; the server answers 404 when it is not a member of
    /// the list, which is distinct from an empty page.
    case around(UUID)
}

/// Every backend call the list and its sheets make. `MVApiClient` is the one real
/// implementation; the protocol exists so the store's paging, merging and optimistic-action
/// rules can be driven by a test double on Linux.
public protocol MVMailListBackend: Sendable {
    func fetchListPage(
        scope: ListScope, threaded: Bool, unreadOnly: Bool, cursor: MVListCursor, limit: Int
    ) async throws -> MessageListResponse
    /// The in-folder quick filter: a chronological search over subject, sender and recipients.
    func fetchFilterPage(
        query: String, accountId: UUID?, folderIds: [UUID], unreadOnly: Bool, before: UUID?, limit: Int
    ) async throws -> SearchResponse
    func fetchLocation(messageId: UUID) async throws -> MessageLocation
    func fetchThread(messageId: UUID) async throws -> ThreadResponse
    func sendBulkAction(accountId: UUID, request: BulkActionRequest) async throws -> BulkActionResponse
    func fetchSelectionSnapshot(
        accountId: UUID, folderId: UUID, filter: MVSelectionFilter
    ) async throws -> SelectionSnapshotResponse
    func sendVerdictFeedback(messageId: UUID, accountId: UUID, isSpam: Bool) async throws
    func requestSync(accountId: UUID) async throws
    func fetchFolders(accountId: UUID) async throws -> [FolderResponse]
    func fetchFolderOrder(accountId: UUID) async throws -> FolderOrderResponse
    func fetchAccounts() async throws -> [AccountResponse]
    func fetchSyncStatus(accountId: UUID) async throws -> SyncStatusResponse
    func fetchUnifiedViews() async throws -> [UnifiedFolderResponse]
    func fetchDeadOutbox() async throws -> [OutboxResponse]
    func fetchContactPhotoIndex(accountId: UUID) async throws -> ContactPhotoIndexResponse
}

extension MVApiClient {
    public func fetchContactPhotoIndex(accountId: UUID) async throws -> ContactPhotoIndexResponse {
        try await getContactPhotoIndex(accountId: accountId)
    }
}

extension MVApiClient: MVMailListBackend {

    public func fetchListPage(
        scope: ListScope, threaded: Bool, unreadOnly: Bool, cursor: MVListCursor, limit: Int
    ) async throws -> MessageListResponse {
        var before: UUID?
        var after: UUID?
        var around: UUID?
        switch cursor {
        case .newest: break
        case .olderThan(let id): before = id
        case .newerThan(let id): after = id
        case .around(let id): around = id
        }
        let isSeen: Bool? = unreadOnly ? false : nil
        switch scope {
        case .folder(let accountId, let folderId):
            return try await listMessages(
                accountId: accountId, folderId: folderId, threaded: threaded, isSeen: isSeen, before: before,
                after: after, around: around, limit: limit
            )
        case .unified(_, let name):
            return try await listUnifiedMessages(
                viewName: name, threaded: threaded, isSeen: isSeen, before: before, after: after, around: around,
                limit: limit
            )
        }
    }

    public func fetchFilterPage(
        query: String, accountId: UUID?, folderIds: [UUID], unreadOnly: Bool, before: UUID?, limit: Int
    ) async throws -> SearchResponse {
        try await search(
            query: query, accountId: accountId, folderIds: folderIds, fields: [.subject, .from, .to],
            sort: .chronological, isSeen: unreadOnly ? false : nil, before: before, limit: limit
        )
    }

    public func fetchLocation(messageId: UUID) async throws -> MessageLocation {
        try await locateMessage(id: messageId)
    }

    public func fetchThread(messageId: UUID) async throws -> ThreadResponse {
        try await getThread(messageId: messageId, loadImages: false)
    }

    public func sendBulkAction(accountId: UUID, request: BulkActionRequest) async throws -> BulkActionResponse {
        try await bulkAction(accountId: accountId, request: request)
    }

    public func fetchSelectionSnapshot(
        accountId: UUID, folderId: UUID, filter: MVSelectionFilter
    ) async throws -> SelectionSnapshotResponse {
        try await mintSelection(accountId: accountId, folderId: folderId, filter: filter.rawValue)
    }

    public func sendVerdictFeedback(messageId: UUID, accountId: UUID, isSpam: Bool) async throws {
        _ = try await submitFeedback(messageId: messageId, accountId: accountId, isSpam: isSpam)
    }

    public func requestSync(accountId: UUID) async throws {
        try await triggerSync(accountId: accountId)
    }

    public func fetchFolders(accountId: UUID) async throws -> [FolderResponse] {
        try await listFolders(accountId: accountId)
    }

    public func fetchFolderOrder(accountId: UUID) async throws -> FolderOrderResponse {
        try await getFolderOrder(accountId: accountId)
    }

    public func fetchAccounts() async throws -> [AccountResponse] {
        try await listAccounts()
    }

    public func fetchSyncStatus(accountId: UUID) async throws -> SyncStatusResponse {
        try await getSyncStatus(accountId: accountId)
    }

    public func fetchUnifiedViews() async throws -> [UnifiedFolderResponse] {
        try await listUnifiedFolders()
    }

    public func fetchDeadOutbox() async throws -> [OutboxResponse] {
        try await listOutbox(status: "dead")
    }
}
