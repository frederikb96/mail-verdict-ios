import Foundation

// Mirrors mail_verdict/api/schemas.py's alert and push-subscription shapes, native push (systems
// design §5.05) included — landed on mail-verdict's own main alongside the cross-account
// notifications endpoint (Models/Notification.swift) and MessageSummary/SearchResult's
// has_attachments/verdict_is_spam fields.

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

/// A PATCH of one device's preferences. The server tells a field the body omits (left alone) from
/// one sent as `null` (cleared — for `alert_folder_ids`, back to the arrival-folder default), so
/// the two fields where that matters are double optionals: outer `nil` omits the key, `.some(nil)`
/// sends `null`.
public struct PushSubscriptionUpdate: ContractModel, Codable, Sendable, Equatable {
    public static let schemaName = "PushSubscriptionUpdate"
    public enum ContractKeys: String, CodingKey, CaseIterable {
        case alertFolderIds = "alert_folder_ids", remindersEnabled = "reminders_enabled", label,
            mutedChannels = "muted_channels"
    }
    public typealias CodingKeys = ContractKeys

    public let alertFolderIds: [UUID]??
    public let remindersEnabled: Bool?
    public let label: String??
    /// `nil` leaves the muted set alone; `[]` unmutes every channel.
    public let mutedChannels: [String]?

    public init(
        alertFolderIds: [UUID]?? = nil, remindersEnabled: Bool? = nil, label: String?? = nil,
        mutedChannels: [String]? = nil
    ) {
        self.alertFolderIds = alertFolderIds
        self.remindersEnabled = remindersEnabled
        self.label = label
        self.mutedChannels = mutedChannels
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        if let alertFolderIds {
            if let alertFolderIds {
                try container.encode(alertFolderIds, forKey: .alertFolderIds)
            } else {
                try container.encodeNil(forKey: .alertFolderIds)
            }
        }
        try container.encodeIfPresent(remindersEnabled, forKey: .remindersEnabled)
        if let label {
            if let label {
                try container.encode(label, forKey: .label)
            } else {
                try container.encodeNil(forKey: .label)
            }
        }
        try container.encodeIfPresent(mutedChannels, forKey: .mutedChannels)
    }
}

/// One registered device, web-push or native alike — `transport` is what tells them apart.
public struct PushSubscriptionResponse: ContractModel, Codable, Sendable, Equatable, Identifiable {
    public static let schemaName = "PushSubscriptionResponse"
    public enum ContractKeys: String, CodingKey, CaseIterable {
        case id, transport, label, alertFolderIds = "alert_folder_ids",
            remindersEnabled = "reminders_enabled", mutedChannels = "muted_channels",
            createdAt = "created_at", lastSeenAt = "last_seen_at", failedAt = "failed_at"
    }
    public typealias CodingKeys = ContractKeys

    public enum Transport: String, Sendable, Equatable, Codable {
        case webpush
        case apns
    }

    public let id: UUID
    public let transport: Transport
    public let label: String?
    public let alertFolderIds: [UUID]?
    public let remindersEnabled: Bool
    public let mutedChannels: [String]
    public let createdAt: Date
    public let lastSeenAt: Date?
    public let failedAt: Date?

    public init(
        id: UUID, transport: Transport, label: String?, alertFolderIds: [UUID]?,
        remindersEnabled: Bool, mutedChannels: [String] = [], createdAt: Date, lastSeenAt: Date?,
        failedAt: Date?
    ) {
        self.id = id
        self.transport = transport
        self.label = label
        self.alertFolderIds = alertFolderIds
        self.remindersEnabled = remindersEnabled
        self.mutedChannels = mutedChannels
        self.createdAt = createdAt
        self.lastSeenAt = lastSeenAt
        self.failedAt = failedAt
    }
}

// MARK: - Native push (systems §5.05)

public struct NativePushConfigResponse: ContractModel, Codable, Sendable, Equatable {
    public static let schemaName = "NativePushConfigResponse"
    public enum ContractKeys: String, CodingKey, CaseIterable {
        case available, relayUrls = "relay_urls", reason
    }
    public typealias CodingKeys = ContractKeys

    public let available: Bool
    public let relayUrls: [String]
    public let reason: String?

    public init(available: Bool, relayUrls: [String], reason: String?) {
        self.available = available
        self.relayUrls = relayUrls
        self.reason = reason
    }
}

public struct NativeSubscriptionCreate: ContractModel, Codable, Sendable, Equatable {
    public static let schemaName = "NativeSubscriptionCreate"
    public enum ContractKeys: String, CodingKey, CaseIterable {
        case installationId = "installation_id", relayUrl = "relay_url", ticket,
            contentKey = "content_key", label, mutedChannels = "muted_channels"
    }
    public typealias CodingKeys = ContractKeys

    public let installationId: UUID
    public let relayUrl: String
    public let ticket: String
    /// Standard base64 of exactly 32 random bytes.
    public let contentKey: String
    public let label: String?
    public let mutedChannels: [String]?

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

public struct AlertLookupRequest: ContractModel, Codable, Sendable, Equatable {
    public static let schemaName = "AlertLookupRequest"
    public enum ContractKeys: String, CodingKey, CaseIterable { case ids }
    public typealias CodingKeys = ContractKeys

    public let ids: [UUID]

    public init(ids: [UUID]) {
        self.ids = ids
    }
}

public struct AlertBadgeResponse: ContractModel, Codable, Sendable, Equatable {
    public static let schemaName = "AlertBadgeResponse"
    public enum ContractKeys: String, CodingKey, CaseIterable { case count }
    public typealias CodingKeys = ContractKeys

    public let count: Int

    public init(count: Int) {
        self.count = count
    }
}
