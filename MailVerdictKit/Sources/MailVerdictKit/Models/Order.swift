import Foundation

// Mirrors mail_verdict/api/schemas.py's order shapes (api/orders.py).

/// One row of the orders list -- everything a screen renders without opening the order.
public struct OrderListItem: ContractModel, Codable, Sendable, Equatable, Identifiable {
    public static let schemaName = "OrderListItem"
    public enum ContractKeys: String, CodingKey, CaseIterable {
        case id, merchant, subject, status, title, isOpen = "is_open", icon,
            summaryPreview = "summary_preview", firstMailAt = "first_mail_at",
            lastMailAt = "last_mail_at", mailCount = "mail_count", accountIds = "account_ids",
            textStale = "text_stale", updatedAt = "updated_at"
    }
    public typealias CodingKeys = ContractKeys

    public let id: UUID
    public let merchant: String
    public let subject: String
    public let status: String
    public let title: String
    public let isOpen: Bool
    public let icon: String
    public let summaryPreview: String
    public let firstMailAt: Date?
    public let lastMailAt: Date?
    public let mailCount: Int
    public let accountIds: [UUID]
    public let textStale: Bool
    public let updatedAt: Date

    public init(
        id: UUID, merchant: String, subject: String, status: String, title: String, isOpen: Bool,
        icon: String, summaryPreview: String, firstMailAt: Date?, lastMailAt: Date?, mailCount: Int,
        accountIds: [UUID], textStale: Bool, updatedAt: Date
    ) {
        self.id = id
        self.merchant = merchant
        self.subject = subject
        self.status = status
        self.title = title
        self.isOpen = isOpen
        self.icon = icon
        self.summaryPreview = summaryPreview
        self.firstMailAt = firstMailAt
        self.lastMailAt = lastMailAt
        self.mailCount = mailCount
        self.accountIds = accountIds
        self.textStale = textStale
        self.updatedAt = updatedAt
    }
}

public struct OrderListResponse: ContractModel, Codable, Sendable, Equatable {
    public static let schemaName = "OrderListResponse"
    public enum ContractKeys: String, CodingKey, CaseIterable {
        case items, hasMore = "has_more", nextCursor = "next_cursor"
    }
    public typealias CodingKeys = ContractKeys

    public let items: [OrderListItem]
    public let hasMore: Bool
    public let nextCursor: String?

    public init(items: [OrderListItem], hasMore: Bool, nextCursor: String?) {
        self.items = items
        self.hasMore = hasMore
        self.nextCursor = nextCursor
    }
}

public struct OrderIdentifierOut: ContractModel, Codable, Sendable, Equatable {
    public static let schemaName = "OrderIdentifierOut"
    public enum ContractKeys: String, CodingKey, CaseIterable { case kind, value }
    public typealias CodingKeys = ContractKeys

    public let kind: String
    public let value: String

    public init(kind: String, value: String) {
        self.kind = kind
        self.value = value
    }
}

/// `location` distinguishes a mail still reachable from one that is not: `"gone"` carries no
/// `messageId` and renders as a dimmed, unopenable snapshot (`subject`/`fromAddr`/`receivedAt`
/// taken at attach time) -- see `orders/locate.py`'s own module docstring on the server.
public struct OrderMailOut: ContractModel, Codable, Sendable, Equatable, Identifiable {
    public static let schemaName = "OrderMailOut"
    public enum ContractKeys: String, CodingKey, CaseIterable {
        case key, accountId = "account_id", messageId = "message_id", threadId = "thread_id",
            location, folderId = "folder_id", isSeen = "is_seen", subject, fromAddr = "from_addr",
            receivedAt = "received_at", attachedBy = "attached_by"
    }
    public typealias CodingKeys = ContractKeys

    public var id: UUID { key }
    public let key: UUID
    public let accountId: UUID
    public let messageId: UUID?
    public let threadId: UUID?
    public let location: String
    public let folderId: UUID?
    public let isSeen: Bool?
    public let subject: String
    public let fromAddr: String
    public let receivedAt: Date
    public let attachedBy: String

    public init(
        key: UUID, accountId: UUID, messageId: UUID?, threadId: UUID?, location: String,
        folderId: UUID?, isSeen: Bool?, subject: String, fromAddr: String, receivedAt: Date,
        attachedBy: String
    ) {
        self.key = key
        self.accountId = accountId
        self.messageId = messageId
        self.threadId = threadId
        self.location = location
        self.folderId = folderId
        self.isSeen = isSeen
        self.subject = subject
        self.fromAddr = fromAddr
        self.receivedAt = receivedAt
        self.attachedBy = attachedBy
    }

    /// A mail neither in the mailbox nor in glacier storage -- dimmed, not clickable, per the
    /// design's own row spec.
    public var isGone: Bool { location == "gone" }
}

public struct OrderDocumentOut: ContractModel, Codable, Sendable, Equatable, Identifiable {
    public static let schemaName = "OrderDocumentOut"
    public enum ContractKeys: String, CodingKey, CaseIterable {
        case messageId = "message_id", attachmentId = "attachment_id", filename,
            contentType = "content_type", sizeBytes = "size_bytes", receivedAt = "received_at"
    }
    public typealias CodingKeys = ContractKeys

    public var id: UUID { attachmentId }
    public let messageId: UUID
    public let attachmentId: UUID
    public let filename: String
    public let contentType: String
    public let sizeBytes: Int?
    public let receivedAt: Date

    public init(
        messageId: UUID, attachmentId: UUID, filename: String, contentType: String,
        sizeBytes: Int?, receivedAt: Date
    ) {
        self.messageId = messageId
        self.attachmentId = attachmentId
        self.filename = filename
        self.contentType = contentType
        self.sizeBytes = sizeBytes
        self.receivedAt = receivedAt
    }
}

public struct OrderDetail: ContractModel, Codable, Sendable, Equatable, Identifiable {
    public static let schemaName = "OrderDetail"
    public enum ContractKeys: String, CodingKey, CaseIterable {
        case id, merchant, subject, status, title, isOpen = "is_open", icon,
            summaryPreview = "summary_preview", firstMailAt = "first_mail_at",
            lastMailAt = "last_mail_at", mailCount = "mail_count", accountIds = "account_ids",
            textStale = "text_stale", updatedAt = "updated_at", summary, identifiers, mails,
            documents
    }
    public typealias CodingKeys = ContractKeys

    public let id: UUID
    public let merchant: String
    public let subject: String
    public let status: String
    public let title: String
    public let isOpen: Bool
    public let icon: String
    public let summaryPreview: String
    public let firstMailAt: Date?
    public let lastMailAt: Date?
    public let mailCount: Int
    public let accountIds: [UUID]
    public let textStale: Bool
    public let updatedAt: Date
    public let summary: String
    public let identifiers: [OrderIdentifierOut]
    /// Oldest first -- the server's own order (`order_mails.received_at` ascending).
    public let mails: [OrderMailOut]
    /// Newest first, at most 12 -- the server's own order.
    public let documents: [OrderDocumentOut]

    public init(
        id: UUID, merchant: String, subject: String, status: String, title: String, isOpen: Bool,
        icon: String, summaryPreview: String, firstMailAt: Date?, lastMailAt: Date?, mailCount: Int,
        accountIds: [UUID], textStale: Bool, updatedAt: Date, summary: String,
        identifiers: [OrderIdentifierOut], mails: [OrderMailOut], documents: [OrderDocumentOut]
    ) {
        self.id = id
        self.merchant = merchant
        self.subject = subject
        self.status = status
        self.title = title
        self.isOpen = isOpen
        self.icon = icon
        self.summaryPreview = summaryPreview
        self.firstMailAt = firstMailAt
        self.lastMailAt = lastMailAt
        self.mailCount = mailCount
        self.accountIds = accountIds
        self.textStale = textStale
        self.updatedAt = updatedAt
        self.summary = summary
        self.identifiers = identifiers
        self.mails = mails
        self.documents = documents
    }

    /// The list row this detail was itself opened from carries -- same shape, so the list can be
    /// refreshed in place from a detail read (a rewrite, a merge target) without a second request.
    public var listItem: OrderListItem {
        OrderListItem(
            id: id, merchant: merchant, subject: subject, status: status, title: title,
            isOpen: isOpen, icon: icon, summaryPreview: summaryPreview, firstMailAt: firstMailAt,
            lastMailAt: lastMailAt, mailCount: mailCount, accountIds: accountIds,
            textStale: textStale, updatedAt: updatedAt
        )
    }
}

public struct OrderMergeRequest: ContractModel, Codable, Sendable, Equatable {
    public static let schemaName = "OrderMergeRequest"
    public enum ContractKeys: String, CodingKey, CaseIterable { case into }
    public typealias CodingKeys = ContractKeys

    public let into: UUID

    public init(into: UUID) {
        self.into = into
    }
}

public struct OrderDetachRequest: ContractModel, Codable, Sendable, Equatable {
    public static let schemaName = "OrderDetachRequest"
    public enum ContractKeys: String, CodingKey, CaseIterable { case moveTo = "move_to" }
    public typealias CodingKeys = ContractKeys

    public let moveTo: UUID?

    public init(moveTo: UUID? = nil) {
        self.moveTo = moveTo
    }
}

public struct OrderCatchUpRequest: ContractModel, Codable, Sendable, Equatable {
    public static let schemaName = "OrderCatchUpRequest"
    public enum ContractKeys: String, CodingKey, CaseIterable {
        case accountId = "account_id", days, dryRun = "dry_run"
    }
    public typealias CodingKeys = ContractKeys

    public let accountId: UUID
    public let days: Int
    @MVDefaulted<MVDefaultFalse> public var dryRun: Bool

    public init(accountId: UUID, days: Int, dryRun: Bool = false) {
        self.accountId = accountId
        self.days = days
        self.dryRun = dryRun
    }
}

public struct OrderCatchUpResponse: ContractModel, Codable, Sendable, Equatable {
    public static let schemaName = "OrderCatchUpResponse"
    public enum ContractKeys: String, CodingKey, CaseIterable { case considered, passed, queued }
    public typealias CodingKeys = ContractKeys

    public let considered: Int
    public let passed: Int
    public let queued: Int

    public init(considered: Int, passed: Int, queued: Int) {
        self.considered = considered
        self.passed = passed
        self.queued = queued
    }
}
