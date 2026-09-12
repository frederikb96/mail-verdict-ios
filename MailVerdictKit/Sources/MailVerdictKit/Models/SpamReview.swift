import Foundation

// Mirrors mail_verdict/api/schemas.py's verdict-feedback and spam-review shapes.

public struct FeedbackRequest: ContractModel, Codable, Sendable, Equatable {
    public static let schemaName = "FeedbackRequest"
    public enum ContractKeys: String, CodingKey, CaseIterable { case isSpam = "is_spam" }
    public typealias CodingKeys = ContractKeys

    public let isSpam: Bool

    public init(isSpam: Bool) {
        self.isSpam = isSpam
    }
}

public struct FeedbackResponse: ContractModel, Codable, Sendable, Equatable {
    public static let schemaName = "FeedbackResponse"
    public enum ContractKeys: String, CodingKey, CaseIterable {
        case success, messageId = "message_id", isSpam = "is_spam", message
    }
    public typealias CodingKeys = ContractKeys

    public let success: Bool
    public let messageId: UUID
    public let isSpam: Bool
    public let message: String?

    public init(success: Bool, messageId: UUID, isSpam: Bool, message: String?) {
        self.success = success
        self.messageId = messageId
        self.isSpam = isSpam
        self.message = message
    }
}

public struct SpamReviewItem: ContractModel, Codable, Sendable, Equatable, Identifiable {
    public static let schemaName = "SpamReviewItem"
    public enum ContractKeys: String, CodingKey, CaseIterable {
        case messageId = "message_id", accountId = "account_id", folderId = "folder_id",
            isJunk = "is_junk", subject, fromAddr = "from_addr", receivedAt = "received_at",
            snippet, verdictId = "verdict_id", modelUsed = "model_used", reasoning,
            verdictCreatedAt = "verdict_created_at"
    }
    public typealias CodingKeys = ContractKeys

    public var id: UUID { messageId }
    public let messageId: UUID
    public let accountId: UUID
    public let folderId: UUID
    public let isJunk: Bool
    public let subject: String?
    public let fromAddr: String?
    public let receivedAt: Date?
    public let snippet: String?
    public let verdictId: UUID
    public let modelUsed: String?
    public let reasoning: String?
    public let verdictCreatedAt: Date

    public init(
        messageId: UUID, accountId: UUID, folderId: UUID, isJunk: Bool, subject: String?,
        fromAddr: String?, receivedAt: Date?, snippet: String?, verdictId: UUID,
        modelUsed: String?, reasoning: String?, verdictCreatedAt: Date
    ) {
        self.messageId = messageId
        self.accountId = accountId
        self.folderId = folderId
        self.isJunk = isJunk
        self.subject = subject
        self.fromAddr = fromAddr
        self.receivedAt = receivedAt
        self.snippet = snippet
        self.verdictId = verdictId
        self.modelUsed = modelUsed
        self.reasoning = reasoning
        self.verdictCreatedAt = verdictCreatedAt
    }
}

public struct SpamReviewListResponse: ContractModel, Codable, Sendable, Equatable {
    public static let schemaName = "SpamReviewListResponse"
    public enum ContractKeys: String, CodingKey, CaseIterable {
        case items, hasMore = "has_more", nextCursor = "next_cursor"
    }
    public typealias CodingKeys = ContractKeys

    public let items: [SpamReviewItem]
    public let hasMore: Bool
    public let nextCursor: String?

    public init(items: [SpamReviewItem], hasMore: Bool, nextCursor: String?) {
        self.items = items
        self.hasMore = hasMore
        self.nextCursor = nextCursor
    }
}
