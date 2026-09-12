import Foundation

// Mirrors mail_verdict/api/schemas.py's account shapes.

public struct AccountResponse: ContractModel, Codable, Sendable, Equatable, Identifiable {
    public static let schemaName = "AccountResponse"
    public enum ContractKeys: String, CodingKey, CaseIterable {
        case id, name, imapHost = "imap_host", imapPort = "imap_port", imapUser = "imap_user",
            smtpHost = "smtp_host", smtpPort = "smtp_port", smtpUser = "smtp_user",
            isActive = "is_active", state, stateError = "state_error", capabilities,
            createdAt = "created_at", updatedAt = "updated_at", emoji,
            spamEnabled = "spam_enabled", folderOrder = "folder_order",
            trashRetentionDays = "trash_retention_days", junkRetentionDays = "junk_retention_days"
    }
    public typealias CodingKeys = ContractKeys

    public let id: UUID
    public let name: String
    public let imapHost: String
    public let imapPort: Int
    public let imapUser: String
    public let smtpHost: String?
    public let smtpPort: Int?
    public let smtpUser: String?
    @MVDefaulted<MVDefaultTrue> public var isActive: Bool
    @MVDefaulted<MVDefaultAccountStateCreated> public var state: String
    public let stateError: String?
    public let capabilities: [String: MVAnyJSON]?
    public let createdAt: Date
    public let updatedAt: Date
    public let emoji: String?
    @MVDefaulted<MVDefaultFalse> public var spamEnabled: Bool
    public let folderOrder: [String]?
    public let trashRetentionDays: Int?
    public let junkRetentionDays: Int?

    public init(
        id: UUID, name: String, imapHost: String, imapPort: Int, imapUser: String,
        smtpHost: String?, smtpPort: Int?, smtpUser: String?, isActive: Bool = true,
        state: String = "created", stateError: String?, capabilities: [String: MVAnyJSON]?,
        createdAt: Date, updatedAt: Date, emoji: String?, spamEnabled: Bool = false,
        folderOrder: [String]?, trashRetentionDays: Int?, junkRetentionDays: Int?
    ) {
        self.id = id
        self.name = name
        self.imapHost = imapHost
        self.imapPort = imapPort
        self.imapUser = imapUser
        self.smtpHost = smtpHost
        self.smtpPort = smtpPort
        self.smtpUser = smtpUser
        self.isActive = isActive
        self.state = state
        self.stateError = stateError
        self.capabilities = capabilities
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.emoji = emoji
        self.spamEnabled = spamEnabled
        self.folderOrder = folderOrder
        self.trashRetentionDays = trashRetentionDays
        self.junkRetentionDays = junkRetentionDays
    }
}

public struct AccountCreateRequest: ContractModel, Codable, Sendable, Equatable {
    public static let schemaName = "AccountCreateRequest"
    public enum ContractKeys: String, CodingKey, CaseIterable {
        case name, imapHost = "imap_host", imapPort = "imap_port", imapUser = "imap_user",
            imapPassword = "imap_password", smtpHost = "smtp_host", smtpPort = "smtp_port",
            smtpUser = "smtp_user", smtpPassword = "smtp_password", isActive = "is_active",
            emoji, spamEnabled = "spam_enabled", trashRetentionDays = "trash_retention_days",
            junkRetentionDays = "junk_retention_days"
    }
    public typealias CodingKeys = ContractKeys

    public let name: String
    public let imapHost: String
    @MVDefaulted<MVDefaultImapPort> public var imapPort: Int
    public let imapUser: String
    public let imapPassword: String?
    public let smtpHost: String?
    public let smtpPort: Int?
    public let smtpUser: String?
    public let smtpPassword: String?
    @MVDefaulted<MVDefaultTrue> public var isActive: Bool
    public let emoji: String?
    @MVDefaulted<MVDefaultFalse> public var spamEnabled: Bool
    public let trashRetentionDays: Int?
    public let junkRetentionDays: Int?

    public init(
        name: String, imapHost: String, imapPort: Int = 993, imapUser: String,
        imapPassword: String? = nil, smtpHost: String? = nil, smtpPort: Int? = nil,
        smtpUser: String? = nil, smtpPassword: String? = nil, isActive: Bool = true,
        emoji: String? = nil, spamEnabled: Bool = false, trashRetentionDays: Int? = nil,
        junkRetentionDays: Int? = nil
    ) {
        self.name = name
        self.imapHost = imapHost
        self.imapPort = imapPort
        self.imapUser = imapUser
        self.imapPassword = imapPassword
        self.smtpHost = smtpHost
        self.smtpPort = smtpPort
        self.smtpUser = smtpUser
        self.smtpPassword = smtpPassword
        self.isActive = isActive
        self.emoji = emoji
        self.spamEnabled = spamEnabled
        self.trashRetentionDays = trashRetentionDays
        self.junkRetentionDays = junkRetentionDays
    }
}

public struct AccountUpdateRequest: ContractModel, Codable, Sendable, Equatable {
    public static let schemaName = "AccountUpdateRequest"
    public enum ContractKeys: String, CodingKey, CaseIterable {
        case name, imapPassword = "imap_password", smtpHost = "smtp_host",
            smtpPort = "smtp_port", smtpUser = "smtp_user", smtpPassword = "smtp_password",
            isActive = "is_active", emoji, spamEnabled = "spam_enabled",
            trashRetentionDays = "trash_retention_days", junkRetentionDays = "junk_retention_days"
    }
    public typealias CodingKeys = ContractKeys

    public let name: String?
    public let imapPassword: String?
    public let smtpHost: String?
    public let smtpPort: Int?
    public let smtpUser: String?
    public let smtpPassword: String?
    public let isActive: Bool?
    public let emoji: String?
    public let spamEnabled: Bool?
    /// `nil` leaves retention alone; `.some(nil)` clears it back to "Off" (`AccountResponse`'s
    /// own doc comment: "NULL/omitted is off"); `.some(.some(days))` sets it. `PATCH
    /// /accounts/{id}` reads its body with Pydantic's `exclude_unset`, so only an explicit `null`
    /// — never an omitted key — turns retention off; `encode(to:)` is what tells the two apart.
    public let trashRetentionDays: Int??
    public let junkRetentionDays: Int??

    public init(
        name: String? = nil, imapPassword: String? = nil, smtpHost: String? = nil,
        smtpPort: Int? = nil, smtpUser: String? = nil, smtpPassword: String? = nil,
        isActive: Bool? = nil, emoji: String? = nil, spamEnabled: Bool? = nil,
        trashRetentionDays: Int?? = nil, junkRetentionDays: Int?? = nil
    ) {
        self.name = name
        self.imapPassword = imapPassword
        self.smtpHost = smtpHost
        self.smtpPort = smtpPort
        self.smtpUser = smtpUser
        self.smtpPassword = smtpPassword
        self.isActive = isActive
        self.emoji = emoji
        self.spamEnabled = spamEnabled
        self.trashRetentionDays = trashRetentionDays
        self.junkRetentionDays = junkRetentionDays
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(name, forKey: .name)
        try container.encodeIfPresent(imapPassword, forKey: .imapPassword)
        try container.encodeIfPresent(smtpHost, forKey: .smtpHost)
        try container.encodeIfPresent(smtpPort, forKey: .smtpPort)
        try container.encodeIfPresent(smtpUser, forKey: .smtpUser)
        try container.encodeIfPresent(smtpPassword, forKey: .smtpPassword)
        try container.encodeIfPresent(isActive, forKey: .isActive)
        try container.encodeIfPresent(emoji, forKey: .emoji)
        try container.encodeIfPresent(spamEnabled, forKey: .spamEnabled)
        if let trashRetentionDays {
            if let trashRetentionDays {
                try container.encode(trashRetentionDays, forKey: .trashRetentionDays)
            } else {
                try container.encodeNil(forKey: .trashRetentionDays)
            }
        }
        if let junkRetentionDays {
            if let junkRetentionDays {
                try container.encode(junkRetentionDays, forKey: .junkRetentionDays)
            } else {
                try container.encodeNil(forKey: .junkRetentionDays)
            }
        }
    }
}

public struct SyncStatusResponse: ContractModel, Codable, Sendable, Equatable {
    public static let schemaName = "SyncStatusResponse"
    public enum ContractKeys: String, CodingKey, CaseIterable {
        case accountId = "account_id", state, stateError = "state_error",
            lastFullSync = "last_full_sync", lastIncrSync = "last_incr_sync",
            syncTier = "sync_tier", foldersSynced = "folders_synced",
            foldersTotal = "folders_total", messagesSynced = "messages_synced",
            errorCount = "error_count", lastError = "last_error", updatedAt = "updated_at"
    }
    public typealias CodingKeys = ContractKeys

    public let accountId: UUID
    public let state: String
    public let stateError: String?
    public let lastFullSync: Date?
    public let lastIncrSync: Date?
    public let syncTier: String?
    @MVDefaulted<MVDefaultZero> public var foldersSynced: Int
    @MVDefaulted<MVDefaultZero> public var foldersTotal: Int
    @MVDefaulted<MVDefaultZero> public var messagesSynced: Int
    @MVDefaulted<MVDefaultZero> public var errorCount: Int
    public let lastError: String?
    public let updatedAt: Date?

    public init(
        accountId: UUID, state: String, stateError: String?, lastFullSync: Date?,
        lastIncrSync: Date?, syncTier: String?, foldersSynced: Int = 0, foldersTotal: Int = 0,
        messagesSynced: Int = 0, errorCount: Int = 0, lastError: String?, updatedAt: Date?
    ) {
        self.accountId = accountId
        self.state = state
        self.stateError = stateError
        self.lastFullSync = lastFullSync
        self.lastIncrSync = lastIncrSync
        self.syncTier = syncTier
        self.foldersSynced = foldersSynced
        self.foldersTotal = foldersTotal
        self.messagesSynced = messagesSynced
        self.errorCount = errorCount
        self.lastError = lastError
        self.updatedAt = updatedAt
    }
}
