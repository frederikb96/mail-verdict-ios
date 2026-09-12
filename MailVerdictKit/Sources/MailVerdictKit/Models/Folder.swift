import Foundation

// Mirrors mail_verdict/api/schemas.py's folder shapes.

public struct FolderResponse: ContractModel, Codable, Sendable, Equatable, Identifiable {
    public static let schemaName = "FolderResponse"
    public enum ContractKeys: String, CodingKey, CaseIterable {
        case id, accountId = "account_id", imapName = "imap_name",
            displayName = "display_name", specialUse = "special_use",
            mailboxId = "mailbox_id", initialSyncDone = "initial_sync_done",
            backfillTotal = "backfill_total", idleRequested = "idle_requested",
            idleStatus = "idle_status", lastSyncedAt = "last_synced_at",
            syncError = "sync_error", createdAt = "created_at", unreadCount = "unread_count",
            totalCount = "total_count", isVisible = "is_visible",
            unifiedViewIds = "unified_view_ids"
    }
    public typealias CodingKeys = ContractKeys

    public let id: UUID
    public let accountId: UUID
    public let imapName: String
    public let displayName: String?
    public let specialUse: String?
    public let mailboxId: String?
    @MVDefaulted<MVDefaultFalse> public var initialSyncDone: Bool
    public let backfillTotal: Int?
    @MVDefaulted<MVDefaultFalse> public var idleRequested: Bool
    public let idleStatus: String?
    public let lastSyncedAt: Date?
    public let syncError: String?
    public let createdAt: Date?
    @MVDefaulted<MVDefaultZero> public var unreadCount: Int
    @MVDefaulted<MVDefaultZero> public var totalCount: Int
    @MVDefaulted<MVDefaultTrue> public var isVisible: Bool
    @MVDefaulted<MVDefaultEmptyArray<UUID>> public var unifiedViewIds: [UUID]

    public init(
        id: UUID, accountId: UUID, imapName: String, displayName: String?, specialUse: String?,
        mailboxId: String?, initialSyncDone: Bool = false, backfillTotal: Int?,
        idleRequested: Bool = false, idleStatus: String?, lastSyncedAt: Date?,
        syncError: String?, createdAt: Date?, unreadCount: Int = 0, totalCount: Int = 0,
        isVisible: Bool = true, unifiedViewIds: [UUID] = []
    ) {
        self.id = id
        self.accountId = accountId
        self.imapName = imapName
        self.displayName = displayName
        self.specialUse = specialUse
        self.mailboxId = mailboxId
        self.initialSyncDone = initialSyncDone
        self.backfillTotal = backfillTotal
        self.idleRequested = idleRequested
        self.idleStatus = idleStatus
        self.lastSyncedAt = lastSyncedAt
        self.syncError = syncError
        self.createdAt = createdAt
        self.unreadCount = unreadCount
        self.totalCount = totalCount
        self.isVisible = isVisible
        self.unifiedViewIds = unifiedViewIds
    }
}

public struct FolderPrefsUpdate: ContractModel, Codable, Sendable, Equatable {
    public static let schemaName = "FolderPrefsUpdate"
    public enum ContractKeys: String, CodingKey, CaseIterable {
        case isVisible = "is_visible", displayName = "display_name",
            unifiedViewIds = "unified_view_ids", specialUseOverride = "special_use_override",
            realTime = "real_time"
    }
    public typealias CodingKeys = ContractKeys

    public let isVisible: Bool?
    public let displayName: String?
    public let unifiedViewIds: [UUID]?
    public let specialUseOverride: String?
    public let realTime: Bool?

    public init(
        isVisible: Bool? = nil, displayName: String? = nil, unifiedViewIds: [UUID]? = nil,
        specialUseOverride: String? = nil, realTime: Bool? = nil
    ) {
        self.isVisible = isVisible
        self.displayName = displayName
        self.unifiedViewIds = unifiedViewIds
        self.specialUseOverride = specialUseOverride
        self.realTime = realTime
    }
}

public struct FolderCreateRequest: ContractModel, Codable, Sendable, Equatable {
    public static let schemaName = "FolderCreateRequest"
    public enum ContractKeys: String, CodingKey, CaseIterable { case name, parentId = "parent_id" }
    public typealias CodingKeys = ContractKeys

    public let name: String
    public let parentId: UUID?

    public init(name: String, parentId: UUID? = nil) {
        self.name = name
        self.parentId = parentId
    }
}

public struct FolderOrderItem: ContractModel, Codable, Sendable, Equatable, Identifiable {
    public static let schemaName = "FolderOrderItem"
    public enum ContractKeys: String, CodingKey, CaseIterable {
        case folderId = "folder_id", imapName = "imap_name", displayName = "display_name",
            specialUse = "special_use", isVisible = "is_visible", unreadCount = "unread_count",
            totalCount = "total_count"
    }
    public typealias CodingKeys = ContractKeys

    public var id: UUID { folderId }
    public let folderId: UUID
    public let imapName: String
    public let displayName: String?
    public let specialUse: String?
    @MVDefaulted<MVDefaultTrue> public var isVisible: Bool
    @MVDefaulted<MVDefaultZero> public var unreadCount: Int
    @MVDefaulted<MVDefaultZero> public var totalCount: Int

    public init(
        folderId: UUID, imapName: String, displayName: String?, specialUse: String?,
        isVisible: Bool = true, unreadCount: Int = 0, totalCount: Int = 0
    ) {
        self.folderId = folderId
        self.imapName = imapName
        self.displayName = displayName
        self.specialUse = specialUse
        self.isVisible = isVisible
        self.unreadCount = unreadCount
        self.totalCount = totalCount
    }
}

public struct FolderOrderResponse: ContractModel, Codable, Sendable, Equatable {
    public static let schemaName = "FolderOrderResponse"
    public enum ContractKeys: String, CodingKey, CaseIterable { case folders }
    public typealias CodingKeys = ContractKeys

    public let folders: [FolderOrderItem]

    public init(folders: [FolderOrderItem]) {
        self.folders = folders
    }
}

public struct FolderOrderUpdate: ContractModel, Codable, Sendable, Equatable {
    public static let schemaName = "FolderOrderUpdate"
    public enum ContractKeys: String, CodingKey, CaseIterable { case order }
    public typealias CodingKeys = ContractKeys

    public let order: [UUID]

    public init(order: [UUID]) {
        self.order = order
    }
}
