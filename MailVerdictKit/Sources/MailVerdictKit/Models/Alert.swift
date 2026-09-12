import Foundation

// Mirrors mail_verdict/api/schemas.py's alert and push-subscription shapes.
//
// The native-push additions (NativePushConfigResponse, NativeSubscriptionCreate,
// AlertLookupRequest, AlertBadgeResponse, and the native-transport fields on
// PushSubscriptionResponse/PushSubscriptionUpdate) are not in the vendored contract snapshot yet
// — they are systems design §5.05, landing on mail-verdict in its own slice after this one. They
// do not conform to ContractModel for that reason; re-pin and add conformance once that slice's
// sha carries them. See this block's report for the full list.

public struct AlertResponse: ContractModel, Codable, Sendable, Equatable, Identifiable {
    public static let schemaName = "AlertResponse"
    public enum ContractKeys: String, CodingKey, CaseIterable {
        case id, kind, title, body, url, accountId = "account_id", messageId = "message_id",
            folderId = "folder_id", deliveredAt = "delivered_at", dismissedAt = "dismissed_at",
            createdAt = "created_at"
    }
    public typealias CodingKeys = ContractKeys

    public let id: UUID
    public let kind: String
    public let title: String?
    public let body: String?
    public let url: String?
    public let accountId: UUID?
    public let messageId: UUID?
    public let folderId: UUID?
    public let deliveredAt: Date?
    public let dismissedAt: Date?
    public let createdAt: Date

    public init(
        id: UUID, kind: String, title: String?, body: String?, url: String?, accountId: UUID?,
        messageId: UUID?, folderId: UUID?, deliveredAt: Date?, dismissedAt: Date?, createdAt: Date
    ) {
        self.id = id
        self.kind = kind
        self.title = title
        self.body = body
        self.url = url
        self.accountId = accountId
        self.messageId = messageId
        self.folderId = folderId
        self.deliveredAt = deliveredAt
        self.dismissedAt = dismissedAt
        self.createdAt = createdAt
    }
}

public struct AlertUnseenCountResponse: ContractModel, Codable, Sendable, Equatable {
    public static let schemaName = "AlertUnseenCountResponse"
    public enum ContractKeys: String, CodingKey, CaseIterable { case unseen, byKind = "by_kind" }
    public typealias CodingKeys = ContractKeys

    public let unseen: Int
    public let byKind: [String: Int]

    public init(unseen: Int, byKind: [String: Int]) {
        self.unseen = unseen
        self.byKind = byKind
    }
}

public struct VapidPublicKeyResponse: ContractModel, Codable, Sendable, Equatable {
    public static let schemaName = "VapidPublicKeyResponse"
    public enum ContractKeys: String, CodingKey, CaseIterable { case available, publicKey = "public_key" }
    public typealias CodingKeys = ContractKeys

    public let available: Bool
    public let publicKey: String?

    public init(available: Bool, publicKey: String?) {
        self.available = available
        self.publicKey = publicKey
    }
}

public struct PushSubscriptionKeys: ContractModel, Codable, Sendable, Equatable {
    public static let schemaName = "PushSubscriptionKeys"
    public enum ContractKeys: String, CodingKey, CaseIterable { case p256dh, auth }
    public typealias CodingKeys = ContractKeys

    public let p256dh: String
    public let auth: String

    public init(p256dh: String, auth: String) {
        self.p256dh = p256dh
        self.auth = auth
    }
}

public struct PushSubscriptionCreate: ContractModel, Codable, Sendable, Equatable {
    public static let schemaName = "PushSubscriptionCreate"
    public enum ContractKeys: String, CodingKey, CaseIterable { case endpoint, keys, label }
    public typealias CodingKeys = ContractKeys

    public let endpoint: String
    public let keys: PushSubscriptionKeys
    public let label: String?

    public init(endpoint: String, keys: PushSubscriptionKeys, label: String? = nil) {
        self.endpoint = endpoint
        self.keys = keys
        self.label = label
    }
}

public struct PushSubscriptionUpdate: ContractModel, Codable, Sendable, Equatable {
    public static let schemaName = "PushSubscriptionUpdate"
    public enum ContractKeys: String, CodingKey, CaseIterable {
        case alertFolderIds = "alert_folder_ids", remindersEnabled = "reminders_enabled", label
    }
    public typealias CodingKeys = ContractKeys

    public let alertFolderIds: [UUID]?
    public let remindersEnabled: Bool?
    public let label: String?

    public init(alertFolderIds: [UUID]? = nil, remindersEnabled: Bool? = nil, label: String? = nil) {
        self.alertFolderIds = alertFolderIds
        self.remindersEnabled = remindersEnabled
        self.label = label
    }
}

public struct PushSubscriptionResponse: ContractModel, Codable, Sendable, Equatable, Identifiable {
    public static let schemaName = "PushSubscriptionResponse"
    public enum ContractKeys: String, CodingKey, CaseIterable {
        case id, label, alertFolderIds = "alert_folder_ids",
            remindersEnabled = "reminders_enabled", createdAt = "created_at",
            lastSeenAt = "last_seen_at", failedAt = "failed_at"
    }
    // No `typealias CodingKeys = ContractKeys` here: `transport`/`muted_channels` decode through
    // a wider `CodingKeys` below (not yet in the pinned snapshot), while `ContractKeys` stays
    // exactly the schema's current properties for `ContractTests` to check against.

    public let id: UUID
    public let label: String?
    public let alertFolderIds: [UUID]?
    public let remindersEnabled: Bool
    public let createdAt: Date
    public let lastSeenAt: Date?
    public let failedAt: Date?
    /// Not in the vendored snapshot yet (systems §5.05's `transport`/`muted_channels`
    /// additions) — `nil`/`[]` until the running server has them. Decoded permissively so this
    /// type still works against MV-1-only and MV-1+MV-2 servers alike.
    public let transport: String?
    public let mutedChannels: [String]

    public init(
        id: UUID, label: String?, alertFolderIds: [UUID]?, remindersEnabled: Bool,
        createdAt: Date, lastSeenAt: Date?, failedAt: Date?, transport: String? = nil,
        mutedChannels: [String] = []
    ) {
        self.id = id
        self.label = label
        self.alertFolderIds = alertFolderIds
        self.remindersEnabled = remindersEnabled
        self.createdAt = createdAt
        self.lastSeenAt = lastSeenAt
        self.failedAt = failedAt
        self.transport = transport
        self.mutedChannels = mutedChannels
    }

    enum CodingKeys: String, CodingKey {
        case id, label, alertFolderIds = "alert_folder_ids",
            remindersEnabled = "reminders_enabled", createdAt = "created_at",
            lastSeenAt = "last_seen_at", failedAt = "failed_at", transport,
            mutedChannels = "muted_channels"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        label = try container.decodeIfPresent(String.self, forKey: .label)
        alertFolderIds = try container.decodeIfPresent([UUID].self, forKey: .alertFolderIds)
        remindersEnabled = try container.decode(Bool.self, forKey: .remindersEnabled)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        lastSeenAt = try container.decodeIfPresent(Date.self, forKey: .lastSeenAt)
        failedAt = try container.decodeIfPresent(Date.self, forKey: .failedAt)
        transport = try container.decodeIfPresent(String.self, forKey: .transport)
        mutedChannels = try container.decodeIfPresent([String].self, forKey: .mutedChannels) ?? []
    }
}

// MARK: - Native push (systems §5.05 — beyond the vendored snapshot, see file header)

public struct NativePushConfigResponse: Codable, Sendable, Equatable {
    public let available: Bool
    public let relayUrls: [String]
    public let reason: String?

    enum CodingKeys: String, CodingKey {
        case available, relayUrls = "relay_urls", reason
    }

    public init(available: Bool, relayUrls: [String], reason: String?) {
        self.available = available
        self.relayUrls = relayUrls
        self.reason = reason
    }
}

public struct NativeSubscriptionCreate: Codable, Sendable, Equatable {
    public let installationId: UUID
    public let relayUrl: String
    public let ticket: String
    /// Base64 of exactly 32 bytes.
    public let contentKey: String
    public let label: String?
    public let mutedChannels: [String]?

    enum CodingKeys: String, CodingKey {
        case installationId = "installation_id", relayUrl = "relay_url", ticket,
            contentKey = "content_key", label, mutedChannels = "muted_channels"
    }

    public init(
        installationId: UUID, relayUrl: String, ticket: String, contentKey: String,
        label: String? = nil, mutedChannels: [String]? = nil
    ) {
        self.installationId = installationId
        self.relayUrl = relayUrl
        self.ticket = ticket
        self.contentKey = contentKey
        self.label = label
        self.mutedChannels = mutedChannels
    }
}

public struct AlertLookupRequest: Codable, Sendable, Equatable {
    public let ids: [UUID]

    public init(ids: [UUID]) {
        self.ids = ids
    }
}

public struct AlertBadgeResponse: Codable, Sendable, Equatable {
    public let count: Int

    public init(count: Int) {
        self.count = count
    }
}
