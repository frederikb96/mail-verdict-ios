import Foundation

// Mirrors mail_verdict/api/schemas.py's outbox (send/draft) and undo-send staging shapes.

/// Not a `ContractModel`: `POST /api/outbox` parses its body by hand (`_parse_request` in
/// `api/outbox.py`, to accept either JSON or multipart) rather than declaring it as a FastAPI
/// request parameter, so this shape never reaches the OpenAPI export at all — there is nothing in
/// the snapshot to check it against even though the backend type is real and this mirrors it.
public struct OutboxCreateRequest: Codable, Sendable, Equatable {
    enum CodingKeys: String, CodingKey {
        case accountId = "account_id", kind, to, cc, bcc, subject, bodyText = "body_text",
            bodyHtml = "body_html", inReplyTo = "in_reply_to", references,
            identityId = "identity_id", replacesMessageId = "replaces_message_id",
            inlineAttachmentContentIds = "inline_attachment_content_ids",
            idempotencyKey = "idempotency_key"
    }

    public enum Kind: String, Sendable, Equatable, Codable { case send, draft }

    public let accountId: UUID
    public let kind: Kind
    public let to: [String]
    public let cc: [String]?
    public let bcc: [String]?
    public let subject: String?
    public let bodyText: String?
    public let bodyHtml: String?
    public let inReplyTo: String?
    public let references: [String]?
    public let identityId: UUID?
    public let replacesMessageId: UUID?
    /// Aligned 1:1 with the multipart `attachments` files a send uploads alongside this JSON
    /// body — `nil` for an ordinary attachment, or the `cid:` content id a `body_html` reference
    /// resolves to for a pasted inline image.
    public let inlineAttachmentContentIds: [String?]?
    public let idempotencyKey: UUID?

    public init(
        accountId: UUID, kind: Kind, to: [String] = [], cc: [String]? = nil,
        bcc: [String]? = nil, subject: String? = nil, bodyText: String? = nil,
        bodyHtml: String? = nil, inReplyTo: String? = nil, references: [String]? = nil,
        identityId: UUID? = nil, replacesMessageId: UUID? = nil,
        inlineAttachmentContentIds: [String?]? = nil, idempotencyKey: UUID? = nil
    ) {
        self.accountId = accountId
        self.kind = kind
        self.to = to
        self.cc = cc
        self.bcc = bcc
        self.subject = subject
        self.bodyText = bodyText
        self.bodyHtml = bodyHtml
        self.inReplyTo = inReplyTo
        self.references = references
        self.identityId = identityId
        self.replacesMessageId = replacesMessageId
        self.inlineAttachmentContentIds = inlineAttachmentContentIds
        self.idempotencyKey = idempotencyKey
    }
}

public struct OutboxAttachmentSummary: ContractModel, Codable, Sendable, Equatable, Identifiable {
    public static let schemaName = "OutboxAttachmentSummary"
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

public struct OutboxResponse: ContractModel, Codable, Sendable, Equatable, Identifiable {
    public static let schemaName = "OutboxResponse"
    public enum ContractKeys: String, CodingKey, CaseIterable {
        case id, accountId = "account_id", kind, status, fromAddr = "from_addr", to, cc, bcc,
            subject, error, attachments, createdAt = "created_at", updatedAt = "updated_at"
    }
    public typealias CodingKeys = ContractKeys

    public let id: UUID
    public let accountId: UUID
    public let kind: String
    public let status: String
    public let fromAddr: String?
    @MVDefaulted<MVDefaultEmptyArray<String>> public var to: [String]
    public let cc: [String]?
    public let bcc: [String]?
    public let subject: String?
    public let error: String?
    @MVDefaulted<MVDefaultEmptyArray<OutboxAttachmentSummary>> public var attachments: [OutboxAttachmentSummary]
    public let createdAt: Date
    public let updatedAt: Date

    public init(
        id: UUID, accountId: UUID, kind: String, status: String, fromAddr: String?,
        to: [String] = [], cc: [String]?, bcc: [String]?, subject: String?, error: String?,
        attachments: [OutboxAttachmentSummary] = [], createdAt: Date, updatedAt: Date
    ) {
        self.id = id
        self.accountId = accountId
        self.kind = kind
        self.status = status
        self.fromAddr = fromAddr
        self.to = to
        self.cc = cc
        self.bcc = bcc
        self.subject = subject
        self.error = error
        self.attachments = attachments
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

public struct PendingSendAttachmentSummary: ContractModel, Codable, Sendable, Equatable, Identifiable {
    public static let schemaName = "PendingSendAttachmentSummary"
    public enum ContractKeys: String, CodingKey, CaseIterable {
        case id, filename, contentType = "content_type", sizeBytes = "size_bytes",
            contentId = "content_id"
    }
    public typealias CodingKeys = ContractKeys

    public let id: UUID
    public let filename: String?
    public let contentType: String?
    public let sizeBytes: Int?
    /// Set for a pasted inline image — the `cid:<content_id>` its `body_html` references.
    public let contentId: String?

    public init(id: UUID, filename: String?, contentType: String?, sizeBytes: Int?, contentId: String?) {
        self.id = id
        self.filename = filename
        self.contentType = contentType
        self.sizeBytes = sizeBytes
        self.contentId = contentId
    }
}

public struct PendingSendResponse: ContractModel, Codable, Sendable, Equatable, Identifiable {
    public static let schemaName = "PendingSendResponse"
    public enum ContractKeys: String, CodingKey, CaseIterable {
        case id, accountId = "account_id", sendAfter = "send_after", createdAt = "created_at",
            fromAddr = "from_addr", to, cc, bcc, subject, bodyHtml = "body_html",
            inReplyTo = "in_reply_to", references, replacesMessageId = "replaces_message_id",
            attachments
    }
    public typealias CodingKeys = ContractKeys

    public let id: UUID
    public let accountId: UUID
    /// Present on every pending row — this is the field `MVOutboxCreateResult` discriminates on:
    /// a send held inside its undo window has one, an ordinary `OutboxResponse` never does.
    public let sendAfter: Date
    public let createdAt: Date
    public let fromAddr: String?
    @MVDefaulted<MVDefaultEmptyArray<String>> public var to: [String]
    public let cc: [String]?
    public let bcc: [String]?
    public let subject: String?
    public let bodyHtml: String?
    public let inReplyTo: String?
    public let references: [String]?
    public let replacesMessageId: UUID?
    @MVDefaulted<MVDefaultEmptyArray<PendingSendAttachmentSummary>> public var attachments:
        [PendingSendAttachmentSummary]

    public init(
        id: UUID, accountId: UUID, sendAfter: Date, createdAt: Date, fromAddr: String?,
        to: [String] = [], cc: [String]?, bcc: [String]?, subject: String?, bodyHtml: String?,
        inReplyTo: String?, references: [String]?, replacesMessageId: UUID?,
        attachments: [PendingSendAttachmentSummary] = []
    ) {
        self.id = id
        self.accountId = accountId
        self.sendAfter = sendAfter
        self.createdAt = createdAt
        self.fromAddr = fromAddr
        self.to = to
        self.cc = cc
        self.bcc = bcc
        self.subject = subject
        self.bodyHtml = bodyHtml
        self.inReplyTo = inReplyTo
        self.references = references
        self.replacesMessageId = replacesMessageId
        self.attachments = attachments
    }
}

/// `POST /outbox` answers one of two shapes, distinguishable only by content: a plain send or
/// draft becomes `OutboxResponse` immediately; a send with `settings.outbox.undo_send_seconds`
/// above zero is held in staging first and comes back as `PendingSendResponse` instead — the
/// backend's own docstring on `create_outbox` names `send_after`'s presence as exactly that
/// signal, so decoding tries the pending shape (the one with a field the other never has) first.
public enum MVOutboxCreateResult: Sendable, Equatable, Decodable {
    case sent(OutboxResponse)
    case pending(PendingSendResponse)

    public init(from decoder: Decoder) throws {
        if let pending = try? PendingSendResponse(from: decoder) {
            self = .pending(pending)
            return
        }
        self = .sent(try OutboxResponse(from: decoder))
    }
}
