import Foundation

// Mirrors mail_verdict/api/schemas.py's bulk-action shapes — see that file for why a selection
// is minted server-side rather than a client ever holding every id of a "select all" scope.

public enum MVBulkAction: String, Sendable, Equatable, CaseIterable, Codable {
    case move
    case markRead = "mark_read"
    case markUnread = "mark_unread"
    case flag
    case unflag
    case archive
    case trash
    case expunge
    case spam
    case notSpam = "not_spam"
}

public struct BulkActionScope: ContractModel, Codable, Sendable, Equatable {
    public static let schemaName = "BulkActionScope"
    public enum ContractKeys: String, CodingKey, CaseIterable {
        case folderId = "folder_id", filter, excludeIds = "exclude_ids", snapshotAt = "snapshot_at"
    }
    public typealias CodingKeys = ContractKeys

    public let folderId: UUID
    /// `"unread"` or `"all"`, or omitted for no predicate filter on top of the scope itself.
    public let filter: String?
    @MVDefaulted<MVDefaultEmptyArray<UUID>> public var excludeIds: [UUID]
    public let snapshotAt: Date

    public init(folderId: UUID, filter: String? = nil, excludeIds: [UUID] = [], snapshotAt: Date) {
        self.folderId = folderId
        self.filter = filter
        self.excludeIds = excludeIds
        self.snapshotAt = snapshotAt
    }
}

public struct BulkActionRequest: ContractModel, Codable, Sendable, Equatable {
    public static let schemaName = "BulkActionRequest"
    public enum ContractKeys: String, CodingKey, CaseIterable {
        case action, targetFolderId = "target_folder_id", ids, scope,
            expandThreads = "expand_threads", confirmMessageCount = "confirm_message_count",
            idempotencyKey = "idempotency_key", expectedFolderIds = "expected_folder_ids",
            expandThreadsThrough = "expand_threads_through"
    }
    public typealias CodingKeys = ContractKeys

    public let action: MVBulkAction
    public let targetFolderId: UUID?
    public let ids: [UUID]?
    public let scope: BulkActionScope?
    @MVDefaulted<MVDefaultFalse> public var expandThreads: Bool
    public let confirmMessageCount: Int?
    /// The same key on a repeated request makes the server answer with the first one's response
    /// instead of applying the action again.
    public let idempotencyKey: UUID?
    /// Per id, the folder it was seen in, keyed by the id's string form — the JSON object the
    /// server reads. A message no longer there is left alone and listed in `skipped_ids`.
    public let expectedFolderIds: [String: UUID]?
    /// With `expand_threads`: only conversation members mirrored by this instant are included.
    public let expandThreadsThrough: Date?

    public init(
        action: MVBulkAction, targetFolderId: UUID? = nil, ids: [UUID]? = nil,
        scope: BulkActionScope? = nil, expandThreads: Bool = false,
        confirmMessageCount: Int? = nil, idempotencyKey: UUID? = nil, expectedFolderIds: [UUID: UUID]? = nil,
        expandThreadsThrough: Date? = nil
    ) {
        self.action = action
        self.targetFolderId = targetFolderId
        self.ids = ids
        self.scope = scope
        self.expandThreads = expandThreads
        self.confirmMessageCount = confirmMessageCount
        self.idempotencyKey = idempotencyKey
        self.expectedFolderIds = expectedFolderIds.map { expected in
            Dictionary(uniqueKeysWithValues: expected.map { ($0.key.uuidString.lowercased(), $0.value) })
        }
        self.expandThreadsThrough = expandThreadsThrough
    }
}

public struct BulkActionSource: ContractModel, Codable, Sendable, Equatable {
    public static let schemaName = "BulkActionSource"
    public enum ContractKeys: String, CodingKey, CaseIterable { case id, folderId = "folder_id" }
    public typealias CodingKeys = ContractKeys

    public let id: UUID
    public let folderId: UUID

    public init(id: UUID, folderId: UUID) {
        self.id = id
        self.folderId = folderId
    }
}

public struct BulkActionResponse: ContractModel, Codable, Sendable, Equatable {
    public static let schemaName = "BulkActionResponse"
    public enum ContractKeys: String, CodingKey, CaseIterable {
        case success, action, affectedCount = "affected_count", errors, sources,
            targetFolderId = "target_folder_id", skippedIds = "skipped_ids"
    }
    public typealias CodingKeys = ContractKeys

    public let success: Bool
    public let action: String
    public let affectedCount: Int
    @MVDefaulted<MVDefaultEmptyArray<String>> public var errors: [String]
    @MVDefaulted<MVDefaultEmptyArray<BulkActionSource>> public var sources: [BulkActionSource]
    /// The folder a moving action filed the messages into — where an undo expects to find them.
    public let targetFolderId: UUID?
    /// Named ids not acted on: gone, or no longer in the folder `expected_folder_ids` named.
    @MVDefaulted<MVDefaultEmptyArray<UUID>> public var skippedIds: [UUID]

    public init(
        success: Bool, action: String, affectedCount: Int, errors: [String] = [],
        sources: [BulkActionSource] = [], targetFolderId: UUID? = nil, skippedIds: [UUID] = []
    ) {
        self.success = success
        self.action = action
        self.affectedCount = affectedCount
        self.errors = errors
        self.sources = sources
        self.targetFolderId = targetFolderId
        self.skippedIds = skippedIds
    }
}

public struct SelectionSnapshotResponse: ContractModel, Codable, Sendable, Equatable {
    public static let schemaName = "SelectionSnapshotResponse"
    public enum ContractKeys: String, CodingKey, CaseIterable {
        case snapshotAt = "snapshot_at", count
    }
    public typealias CodingKeys = ContractKeys

    public let snapshotAt: Date
    public let count: Int

    public init(snapshotAt: Date, count: Int) {
        self.snapshotAt = snapshotAt
        self.count = count
    }
}
