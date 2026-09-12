import Foundation

// Mirrors mail_verdict/api/schemas.py and api/unified.py's unified-view shapes.

public struct UnifiedFolderSource: ContractModel, Codable, Sendable, Equatable {
    public static let schemaName = "UnifiedFolderSource"
    public enum ContractKeys: String, CodingKey, CaseIterable {
        case accountId = "account_id", accountName = "account_name",
            accountEmoji = "account_emoji", folderId = "folder_id", imapName = "imap_name",
            specialUse = "special_use"
    }
    public typealias CodingKeys = ContractKeys

    public let accountId: UUID
    public let accountName: String
    public let accountEmoji: String?
    public let folderId: UUID
    public let imapName: String
    public let specialUse: String?

    public init(
        accountId: UUID, accountName: String, accountEmoji: String?, folderId: UUID,
        imapName: String, specialUse: String?
    ) {
        self.accountId = accountId
        self.accountName = accountName
        self.accountEmoji = accountEmoji
        self.folderId = folderId
        self.imapName = imapName
        self.specialUse = specialUse
    }
}

public struct UnifiedFolderResponse: ContractModel, Codable, Sendable, Equatable, Identifiable {
    public static let schemaName = "UnifiedFolderResponse"
    public enum ContractKeys: String, CodingKey, CaseIterable {
        case id, unifiedName = "unified_name", emoji, folders, unreadCount = "unread_count",
            totalCount = "total_count"
    }
    public typealias CodingKeys = ContractKeys

    public let id: UUID
    public let unifiedName: String
    public let emoji: String?
    public let folders: [UnifiedFolderSource]
    public let unreadCount: Int
    public let totalCount: Int

    public init(
        id: UUID, unifiedName: String, emoji: String?, folders: [UnifiedFolderSource],
        unreadCount: Int, totalCount: Int
    ) {
        self.id = id
        self.unifiedName = unifiedName
        self.emoji = emoji
        self.folders = folders
        self.unreadCount = unreadCount
        self.totalCount = totalCount
    }
}

public struct UnifiedViewCreate: ContractModel, Codable, Sendable, Equatable {
    public static let schemaName = "UnifiedViewCreate"
    public enum ContractKeys: String, CodingKey, CaseIterable { case name, emoji }
    public typealias CodingKeys = ContractKeys

    public let name: String
    public let emoji: String?

    public init(name: String, emoji: String? = nil) {
        self.name = name
        self.emoji = emoji
    }
}

public struct UnifiedViewUpdate: ContractModel, Codable, Sendable, Equatable {
    public static let schemaName = "UnifiedViewUpdate"
    public enum ContractKeys: String, CodingKey, CaseIterable { case name, emoji }
    public typealias CodingKeys = ContractKeys

    public let name: String?
    public let emoji: String?

    public init(name: String? = nil, emoji: String? = nil) {
        self.name = name
        self.emoji = emoji
    }
}

public struct UnifiedViewResponse: ContractModel, Codable, Sendable, Equatable, Identifiable {
    public static let schemaName = "UnifiedViewResponse"
    public enum ContractKeys: String, CodingKey, CaseIterable { case id, name, emoji, position }
    public typealias CodingKeys = ContractKeys

    public let id: UUID
    public let name: String
    public let emoji: String?
    public let position: Int

    public init(id: UUID, name: String, emoji: String?, position: Int) {
        self.id = id
        self.name = name
        self.emoji = emoji
        self.position = position
    }
}

public struct EmojiUpdate: ContractModel, Codable, Sendable, Equatable {
    public static let schemaName = "EmojiUpdate"
    public enum ContractKeys: String, CodingKey, CaseIterable { case emoji }
    public typealias CodingKeys = ContractKeys

    public let emoji: String?

    public init(emoji: String? = nil) {
        self.emoji = emoji
    }
}

public struct UnifiedFolderOrderResponse: ContractModel, Codable, Sendable, Equatable {
    public static let schemaName = "UnifiedFolderOrderResponse"
    public enum ContractKeys: String, CodingKey, CaseIterable { case order }
    public typealias CodingKeys = ContractKeys

    public let order: [String]

    public init(order: [String]) {
        self.order = order
    }
}

public struct UnifiedFolderOrderUpdate: ContractModel, Codable, Sendable, Equatable {
    public static let schemaName = "UnifiedFolderOrderUpdate"
    public enum ContractKeys: String, CodingKey, CaseIterable { case order }
    public typealias CodingKeys = ContractKeys

    public let order: [String]

    public init(order: [String]) {
        self.order = order
    }
}
