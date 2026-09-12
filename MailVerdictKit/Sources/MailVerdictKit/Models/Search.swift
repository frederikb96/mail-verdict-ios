import Foundation

// Mirrors mail_verdict/api/schemas.py and api/search.py / api/embeddings.py's query shapes.

public enum MVSearchField: String, Sendable, Equatable, CaseIterable, Codable {
    case subject, from, to, body
}

public enum MVSearchSort: String, Sendable, Equatable, CaseIterable, Codable {
    case relevance
    case chronological
}

public enum MVSemanticSort: String, Sendable, Equatable, CaseIterable, Codable {
    case relevance
    case chronological
}

public enum MVSemanticStrictness: String, Sendable, Equatable, CaseIterable, Codable {
    case loose, balanced, strict
}

/// A search hit: `MessageSummary`'s full shape (the web's own reasoning — a result carries the
/// same row actions a list row does) plus how the query matched it. The backend's own
/// `SearchResult` schema repeats every `MessageSummary` field rather than nesting it, so this
/// type does the same instead of composing `MessageSummary`.
public struct SearchResult: ContractModel, Codable, Sendable, Equatable, Identifiable {
    public static let schemaName = "SearchResult"
    public enum ContractKeys: String, CodingKey, CaseIterable {
        case id, accountId = "account_id", folderId = "folder_id", threadId = "thread_id",
            subject, fromAddr = "from_addr", toAddrs = "to_addrs", receivedAt = "received_at",
            isSeen = "is_seen", isFlagged = "is_flagged", isAnswered = "is_answered",
            isDraft = "is_draft", snippet, pendingSync = "pending_sync",
            isTruncated = "is_truncated", threadCount = "thread_count",
            unreadInThread = "unread_in_thread", mirroredAt = "mirrored_at",
            matchTier = "match_tier", similarity, hasAttachments = "has_attachments",
            verdictIsSpam = "verdict_is_spam"
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
    public let threadCount: Int?
    public let unreadInThread: Int?
    public let mirroredAt: Date
    @MVDefaulted<MVDefaultZero> public var matchTier: Int
    public let similarity: Double?
    public let hasAttachments: Bool
    public let verdictIsSpam: Bool?

    public init(
        id: UUID, accountId: UUID, folderId: UUID, threadId: UUID, subject: String?,
        fromAddr: String?, toAddrs: MVJSONValue?, receivedAt: Date?, isSeen: Bool = false,
        isFlagged: Bool = false, isAnswered: Bool = false, isDraft: Bool = false,
        snippet: String?, pendingSync: Bool = false, isTruncated: Bool = false,
        threadCount: Int? = nil, unreadInThread: Int? = nil, mirroredAt: Date,
        matchTier: Int = 0, similarity: Double? = nil, hasAttachments: Bool = false,
        verdictIsSpam: Bool? = nil
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
        self.matchTier = matchTier
        self.similarity = similarity
        self.hasAttachments = hasAttachments
        self.verdictIsSpam = verdictIsSpam
    }
}

public struct SearchResponse: ContractModel, Codable, Sendable, Equatable {
    public static let schemaName = "SearchResponse"
    public enum ContractKeys: String, CodingKey, CaseIterable {
        case results, hasMore = "has_more", nextCursor = "next_cursor", query, total
    }
    public typealias CodingKeys = ContractKeys

    public let results: [SearchResult]
    public let hasMore: Bool
    public let nextCursor: String?
    public let query: String
    public let total: Int

    public init(results: [SearchResult], hasMore: Bool, nextCursor: String?, query: String, total: Int) {
        self.results = results
        self.hasMore = hasMore
        self.nextCursor = nextCursor
        self.query = query
        self.total = total
    }
}

public struct SearchDateBoundsResponse: ContractModel, Codable, Sendable, Equatable {
    public static let schemaName = "SearchDateBoundsResponse"
    public enum ContractKeys: String, CodingKey, CaseIterable { case oldest, newest }
    public typealias CodingKeys = ContractKeys

    public let oldest: Date?
    public let newest: Date?

    public init(oldest: Date?, newest: Date?) {
        self.oldest = oldest
        self.newest = newest
    }
}

public struct SemanticSearchResponse: ContractModel, Codable, Sendable, Equatable {
    public static let schemaName = "SemanticSearchResponse"
    public enum ContractKeys: String, CodingKey, CaseIterable {
        case results, query, model, strictness, minSimilarityApplied = "min_similarity_applied"
    }
    public typealias CodingKeys = ContractKeys

    public let results: [SearchResult]
    public let query: String
    public let model: String
    public let strictness: MVSemanticStrictness
    public let minSimilarityApplied: Double

    public init(
        results: [SearchResult], query: String, model: String, strictness: MVSemanticStrictness,
        minSimilarityApplied: Double
    ) {
        self.results = results
        self.query = query
        self.model = model
        self.strictness = strictness
        self.minSimilarityApplied = minSimilarityApplied
    }
}
