import Foundation

// Mirrors mail_verdict/api/schemas.py's message-related shapes. Read that file, not this
// comment, for field meaning — this file only restates the wire shape, in Swift.

public struct TagResponse: ContractModel, Codable, Sendable, Equatable {
    public static let schemaName = "TagResponse"
    public enum ContractKeys: String, CodingKey, CaseIterable { case tagName = "tag_name", source }
    public typealias CodingKeys = ContractKeys

    public let tagName: String
    public let source: String

    public init(tagName: String, source: String) {
        self.tagName = tagName
        self.source = source
    }
}

public struct AttachmentSummary: ContractModel, Codable, Sendable, Equatable, Identifiable {
    public static let schemaName = "AttachmentSummary"
    public enum ContractKeys: String, CodingKey, CaseIterable {
        case id, filename, contentType = "content_type", sizeBytes = "size_bytes"
    }
    public typealias CodingKeys = ContractKeys

    public let id: UUID
    public let filename: String?
    public let contentType: String?
    public let sizeBytes: Int?

    public init(id: UUID, filename: String?, contentType: String?, sizeBytes: Int?) {
        self.id = id
        self.filename = filename
        self.contentType = contentType
        self.sizeBytes = sizeBytes
    }
}

public struct VerdictResponse: ContractModel, Codable, Sendable, Equatable, Identifiable {
    public static let schemaName = "VerdictResponse"
    public enum ContractKeys: String, CodingKey, CaseIterable {
        case id, messageId = "message_id", isSpam = "is_spam", modelUsed = "model_used",
            reasoning, source, createdAt = "created_at"
    }
    public typealias CodingKeys = ContractKeys

    public let id: UUID
    public let messageId: UUID
    public let isSpam: Bool
    public let modelUsed: String?
    public let reasoning: String?
    public let source: String
    public let createdAt: Date

    public init(
        id: UUID, messageId: UUID, isSpam: Bool, modelUsed: String?, reasoning: String?,
        source: String, createdAt: Date
    ) {
        self.id = id
        self.messageId = messageId
        self.isSpam = isSpam
        self.modelUsed = modelUsed
        self.reasoning = reasoning
        self.source = source
        self.createdAt = createdAt
    }
}

/// A list row. `MessageDetail` below and `SearchResult` (Models/Search.swift) repeat the same
/// leading fields rather than composing this type — the backend's own `SearchResult` schema is a
/// flat inheritance (`MessageSummary` plus two fields), not a nested one, so a client decoding it
/// from the wire needs the same flat shape to match.
///
/// `hasAttachments`/`verdictIsSpam` feed the list row's attachment and spam marks.
public struct MessageSummary: ContractModel, Codable, Sendable, Equatable, Identifiable {
    public static let schemaName = "MessageSummary"
    public enum ContractKeys: String, CodingKey, CaseIterable {
        case id, accountId = "account_id", folderId = "folder_id", threadId = "thread_id",
            subject, fromAddr = "from_addr", toAddrs = "to_addrs", receivedAt = "received_at",
            isSeen = "is_seen", isFlagged = "is_flagged", isAnswered = "is_answered",
            isDraft = "is_draft", snippet, pendingSync = "pending_sync",
            isTruncated = "is_truncated", threadCount = "thread_count",
            unreadInThread = "unread_in_thread", mirroredAt = "mirrored_at",
            hasAttachments = "has_attachments", verdictIsSpam = "verdict_is_spam"
    }
    public typealias CodingKeys = ContractKeys

    public let id: UUID
    public let accountId: UUID
    public let folderId: UUID
    public let threadId: UUID
    public let subject: String?
    public let fromAddr: String?
    /// `to_addrs` is an untyped JSON value backend-side (a string, an array, or null depending on
    /// how PostIMAP stored it) — `MVJSONValue` (Models/JSONValue.swift) decodes whichever arrives.
    public let toAddrs: MVJSONValue?
    public let receivedAt: Date?
    @MVDefaulted<MVDefaultFalse> public var isSeen: Bool
    @MVDefaulted<MVDefaultFalse> public var isFlagged: Bool
    @MVDefaulted<MVDefaultFalse> public var isAnswered: Bool
    @MVDefaulted<MVDefaultFalse> public var isDraft: Bool
    public let snippet: String?
    @MVDefaulted<MVDefaultFalse> public var pendingSync: Bool
    @MVDefaulted<MVDefaultFalse> public var isTruncated: Bool
    public let threadCount: Int?
    public let unreadInThread: Int?
    public let mirroredAt: Date
    public let hasAttachments: Bool
    /// The latest spam verdict for this message; `nil` if never classified.
    public let verdictIsSpam: Bool?

    public init(
        id: UUID, accountId: UUID, folderId: UUID, threadId: UUID, subject: String?,
        fromAddr: String?, toAddrs: MVJSONValue?, receivedAt: Date?, isSeen: Bool = false,
        isFlagged: Bool = false, isAnswered: Bool = false, isDraft: Bool = false,
        snippet: String?, pendingSync: Bool = false, isTruncated: Bool = false,
        threadCount: Int? = nil, unreadInThread: Int? = nil, mirroredAt: Date,
        hasAttachments: Bool = false, verdictIsSpam: Bool? = nil
    ) {
        self.id = id
        self.accountId = accountId
        self.folderId = folderId
        self.threadId = threadId
        self.subject = subject
        self.fromAddr = fromAddr
        self.toAddrs = toAddrs
        self.receivedAt = receivedAt
        self.isSeen = isSeen
        self.isFlagged = isFlagged
        self.isAnswered = isAnswered
        self.isDraft = isDraft
        self.snippet = snippet
        self.pendingSync = pendingSync
        self.isTruncated = isTruncated
        self.threadCount = threadCount
        self.unreadInThread = unreadInThread
        self.mirroredAt = mirroredAt
        self.hasAttachments = hasAttachments
        self.verdictIsSpam = verdictIsSpam
    }
}

public struct MessageListResponse: ContractModel, Codable, Sendable, Equatable {
    public static let schemaName = "MessageListResponse"
    public enum ContractKeys: String, CodingKey, CaseIterable {
        case messages, hasMore = "has_more", nextCursor = "next_cursor",
            hasMoreNewer = "has_more_newer", prevCursor = "prev_cursor"
    }
    public typealias CodingKeys = ContractKeys

    public let messages: [MessageSummary]
    public let hasMore: Bool
    public let nextCursor: String?
    @MVDefaulted<MVDefaultFalse> public var hasMoreNewer: Bool
    public let prevCursor: String?

    public init(
        messages: [MessageSummary], hasMore: Bool, nextCursor: String?,
        hasMoreNewer: Bool = false, prevCursor: String? = nil
    ) {
        self.messages = messages
        self.hasMore = hasMore
        self.nextCursor = nextCursor
        self.hasMoreNewer = hasMoreNewer
        self.prevCursor = prevCursor
    }
}

public struct MessageLocation: ContractModel, Codable, Sendable, Equatable {
    public static let schemaName = "MessageLocation"
    public enum ContractKeys: String, CodingKey, CaseIterable {
        case id, accountId = "account_id", folderId = "folder_id", threadId = "thread_id"
    }
    public typealias CodingKeys = ContractKeys

    public let id: UUID
    public let accountId: UUID
    public let folderId: UUID
    public let threadId: UUID

    public init(id: UUID, accountId: UUID, folderId: UUID, threadId: UUID) {
        self.id = id
        self.accountId = accountId
        self.folderId = folderId
        self.threadId = threadId
    }
}

public struct MessageDetail: ContractModel, Codable, Sendable, Equatable, Identifiable {
    public static let schemaName = "MessageDetail"
    public enum ContractKeys: String, CodingKey, CaseIterable {
        case id, accountId = "account_id", folderId = "folder_id", threadId = "thread_id",
            subject, fromAddr = "from_addr", toAddrs = "to_addrs", receivedAt = "received_at",
            isSeen = "is_seen", isFlagged = "is_flagged", isAnswered = "is_answered",
            isDraft = "is_draft", snippet, pendingSync = "pending_sync",
            isTruncated = "is_truncated", messageId = "message_id", ccAddrs = "cc_addrs",
            bccAddrs = "bcc_addrs", replyTo = "reply_to", inReplyTo = "in_reply_to",
            references, bodyText = "body_text", bodyHtml = "body_html", sizeBytes = "size_bytes",
            keywords, hasBlockedImages = "has_blocked_images", imagesAllowed = "images_allowed",
            createdAt = "created_at", tags, attachments, verdict
    }
    public typealias CodingKeys = ContractKeys

    public let id: UUID
    public let accountId: UUID
    public let folderId: UUID
    public let threadId: UUID
    public let subject: String?
    public let fromAddr: String?
    public let toAddrs: MVJSONValue?
    public let receivedAt: Date?
    @MVDefaulted<MVDefaultFalse> public var isSeen: Bool
    @MVDefaulted<MVDefaultFalse> public var isFlagged: Bool
    @MVDefaulted<MVDefaultFalse> public var isAnswered: Bool
    @MVDefaulted<MVDefaultFalse> public var isDraft: Bool
    public let snippet: String?
    @MVDefaulted<MVDefaultFalse> public var pendingSync: Bool
    @MVDefaulted<MVDefaultFalse> public var isTruncated: Bool
    public let messageId: String?
    public let ccAddrs: MVJSONValue?
    public let bccAddrs: MVJSONValue?
    public let replyTo: String?
    public let inReplyTo: String?
    public let references: [String]?
    public let bodyText: String?
    public let bodyHtml: String?
    public let sizeBytes: Int?
    @MVDefaulted<MVDefaultEmptyArray<String>> public var keywords: [String]
    @MVDefaulted<MVDefaultFalse> public var hasBlockedImages: Bool
    @MVDefaulted<MVDefaultFalse> public var imagesAllowed: Bool
    public let createdAt: Date
    @MVDefaulted<MVDefaultEmptyArray<TagResponse>> public var tags: [TagResponse]
    @MVDefaulted<MVDefaultEmptyArray<AttachmentSummary>> public var attachments: [AttachmentSummary]
    public let verdict: VerdictResponse?

    public init(
        id: UUID, accountId: UUID, folderId: UUID, threadId: UUID, subject: String?,
        fromAddr: String?, toAddrs: MVJSONValue?, receivedAt: Date?, isSeen: Bool = false,
        isFlagged: Bool = false, isAnswered: Bool = false, isDraft: Bool = false,
        snippet: String?, pendingSync: Bool = false, isTruncated: Bool = false,
        messageId: String?, ccAddrs: MVJSONValue?, bccAddrs: MVJSONValue?, replyTo: String?,
        inReplyTo: String?, references: [String]?, bodyText: String?, bodyHtml: String?,
        sizeBytes: Int?, keywords: [String] = [], hasBlockedImages: Bool = false,
        imagesAllowed: Bool = false, createdAt: Date, tags: [TagResponse] = [],
        attachments: [AttachmentSummary] = [], verdict: VerdictResponse?
    ) {
        self.id = id
        self.accountId = accountId
        self.folderId = folderId
        self.threadId = threadId
        self.subject = subject
        self.fromAddr = fromAddr
        self.toAddrs = toAddrs
        self.receivedAt = receivedAt
        self.isSeen = isSeen
        self.isFlagged = isFlagged
        self.isAnswered = isAnswered
        self.isDraft = isDraft
        self.snippet = snippet
        self.pendingSync = pendingSync
        self.isTruncated = isTruncated
        self.messageId = messageId
        self.ccAddrs = ccAddrs
        self.bccAddrs = bccAddrs
        self.replyTo = replyTo
        self.inReplyTo = inReplyTo
        self.references = references
        self.bodyText = bodyText
        self.bodyHtml = bodyHtml
        self.sizeBytes = sizeBytes
        self.keywords = keywords
        self.hasBlockedImages = hasBlockedImages
        self.imagesAllowed = imagesAllowed
        self.createdAt = createdAt
        self.tags = tags
        self.attachments = attachments
        self.verdict = verdict
    }
}

public struct ThreadResponse: ContractModel, Codable, Sendable, Equatable {
    public static let schemaName = "ThreadResponse"
    public enum ContractKeys: String, CodingKey, CaseIterable { case messages }
    public typealias CodingKeys = ContractKeys

    public let messages: [MessageDetail]

    public init(messages: [MessageDetail]) {
        self.messages = messages
    }
}

public struct MessageQuoteResponse: ContractModel, Codable, Sendable, Equatable {
    public static let schemaName = "MessageQuoteResponse"
    public enum ContractKeys: String, CodingKey, CaseIterable { case html }
    public typealias CodingKeys = ContractKeys

    public let html: String

    public init(html: String) {
        self.html = html
    }
}

/// The action names `POST /messages/{id}/action` accepts — kept as a plain `String` rather than
/// a closed Swift enum on the request side, matching the wire's own open set of literals without
/// this client needing to recognize a new one before it can send it.
public enum MVMessageAction: String, Sendable, Equatable, CaseIterable, Codable {
    case markRead = "mark_read"
    case markUnread = "mark_unread"
    case flag
    case unflag
    case move
    case archive
    case trash
    case expunge
    case spam
    case notSpam = "not_spam"
    case keywordAdd = "keyword_add"
    case keywordRemove = "keyword_remove"
}

public struct MessageActionRequest: ContractModel, Codable, Sendable, Equatable {
    public static let schemaName = "MessageActionRequest"
    public enum ContractKeys: String, CodingKey, CaseIterable {
        case action, targetFolderId = "target_folder_id", keyword
    }
    public typealias CodingKeys = ContractKeys

    public let action: MVMessageAction
    public let targetFolderId: UUID?
    public let keyword: String?

    public init(action: MVMessageAction, targetFolderId: UUID? = nil, keyword: String? = nil) {
        self.action = action
        self.targetFolderId = targetFolderId
        self.keyword = keyword
    }
}

public struct MessageActionResponse: ContractModel, Codable, Sendable, Equatable {
    public static let schemaName = "MessageActionResponse"
    public enum ContractKeys: String, CodingKey, CaseIterable {
        case success, action, messageId = "message_id", message
    }
    public typealias CodingKeys = ContractKeys

    public let success: Bool
    public let action: String
    public let messageId: UUID
    public let message: String?

    public init(success: Bool, action: String, messageId: UUID, message: String?) {
        self.success = success
        self.action = action
        self.messageId = messageId
        self.message = message
    }
}
