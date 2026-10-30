import Foundation

// Mirrors mail_verdict/api/schemas.py's order shapes (api/orders.py).

/// What an entry is: somewhere to be on a date (`ticket`), goods or a one-off service handed over
/// (`order`), or anything else -- subscriptions, claims, service cases (`other`). A kind a newer
/// server adds reads as `.other`.
public enum OrderKind: String, Codable, Sendable, Equatable, CaseIterable {
    case ticket, order, other

    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = OrderKind(rawValue: raw) ?? .other
    }

    public var label: String {
        switch self {
        case .ticket: return "Ticket"
        case .order: return "Order"
        case .other: return "Other"
        }
    }
}

/// One row of the orders list -- everything a screen renders without opening the order.
public struct OrderListItem: ContractModel, Codable, Sendable, Equatable, Identifiable {
    public static let schemaName = "OrderListItem"
    public enum ContractKeys: String, CodingKey, CaseIterable {
        case id, merchant, subject, status, title, isOpen = "is_open", icon,
            summaryPreview = "summary_preview", firstMailAt = "first_mail_at",
            lastMailAt = "last_mail_at", mailCount = "mail_count", accountIds = "account_ids",
            textStale = "text_stale", updatedAt = "updated_at", isFavorite = "is_favorite",
            isSealed = "is_sealed", openSetBy = "open_set_by", expectedUntil = "expected_until",
            kind, kindSetBy = "kind_set_by", eventStart = "event_start", eventEnd = "event_end",
            timelineDate = "timeline_date", firstActivityAt = "first_activity_at",
            lastActivityAt = "last_activity_at", fileCount = "file_count"
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
    /// Per-order flags a person sets; `@MVDefaulted` so a server that predates them still decodes.
    @MVDefaulted<MVDefaultFalse> public var isFavorite: Bool
    /// A sealed order takes no further mail.
    @MVDefaulted<MVDefaultFalse> public var isSealed: Bool
    /// Who decided the current `isOpen`: `"ai"`, `"user"` or `"auto"`.
    @MVDefaulted<MVDefaultOpenSetByAi> public var openSetBy: String
    /// `YYYY-MM-DD` of the last thing still expected; a date-only value, so kept as the wire string.
    public let expectedUntil: String?
    /// Whether the entry is somewhere to be on a date, goods handed over, or neither.
    @MVDefaulted<MVDefaultOrderKind> public var kind: OrderKind
    /// Who decided `kind`: `"ai"` or `"user"` (a person's choice is never overwritten).
    @MVDefaulted<MVDefaultKindSetByAi> public var kindSetBy: String
    /// `YYYY-MM-DD` dates, kept as wire strings like `expectedUntil`.
    public let eventStart: String?
    public let eventEnd: String?
    /// The day the entry sits on in the ticket timeline: its event start, else the day of its first
    /// activity -- decided once by the server, never recomputed here.
    public let timelineDate: String?
    public let firstActivityAt: Date?
    public let lastActivityAt: Date?
    /// Files a person added by hand (mails are `mailCount`).
    @MVDefaulted<MVDefaultZero> public var fileCount: Int

    public init(
        id: UUID, merchant: String, subject: String, status: String, title: String, isOpen: Bool,
        icon: String, summaryPreview: String, firstMailAt: Date?, lastMailAt: Date?, mailCount: Int,
        accountIds: [UUID], textStale: Bool, updatedAt: Date, isFavorite: Bool = false,
        isSealed: Bool = false, openSetBy: String = "ai", expectedUntil: String? = nil,
        kind: OrderKind = .order, kindSetBy: String = "ai", eventStart: String? = nil,
        eventEnd: String? = nil, timelineDate: String? = nil, firstActivityAt: Date? = nil,
        lastActivityAt: Date? = nil, fileCount: Int = 0
    ) {
        self.isFavorite = isFavorite
        self.isSealed = isSealed
        self.openSetBy = openSetBy
        self.expectedUntil = expectedUntil
        self.kind = kind
        self.kindSetBy = kindSetBy
        self.eventStart = eventStart
        self.eventEnd = eventEnd
        self.timelineDate = timelineDate
        self.firstActivityAt = firstActivityAt
        self.lastActivityAt = lastActivityAt
        self.fileCount = fileCount
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

/// What a key fact is. Unknown kinds a newer server may send read as `.other`, so one new kind
/// never fails a whole order's decode.
public enum OrderFactKind: String, Codable, Sendable, Equatable, CaseIterable {
    case orderNumber = "order_number", bookingCode = "booking_code", ticketNumber = "ticket_number",
        invoiceNumber = "invoice_number", trackingNumber = "tracking_number", date, time, amount,
        place, seat, person, code, link, other

    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = OrderFactKind(rawValue: raw) ?? .other
    }
}

/// A scannable code of a fact, drawn by the server.
public struct OrderCodeOut: ContractModel, Codable, Sendable, Equatable {
    public static let schemaName = "OrderCodeOut"
    public enum ContractKeys: String, CodingKey, CaseIterable {
        case format, payloadText = "payload_text", imageUrl = "image_url", page
    }
    public typealias CodingKeys = ContractKeys

    public let format: String
    /// The printable payload, or `nil` for a binary one.
    public let payloadText: String?
    /// A server path (with the `/api` prefix) of the PNG.
    public let imageUrl: String
    public let page: Int?

    public init(format: String, payloadText: String?, imageUrl: String, page: Int?) {
        self.format = format
        self.payloadText = payloadText
        self.imageUrl = imageUrl
        self.page = page
    }
}

/// One typed key fact of an order, in display order.
public struct OrderFactOut: ContractModel, Codable, Sendable, Equatable, Identifiable {
    public static let schemaName = "OrderFactOut"
    public enum ContractKeys: String, CodingKey, CaseIterable {
        case id, kind, label, value, carrier, trackingUrl = "tracking_url", code,
            documentId = "document_id"
    }
    public typealias CodingKeys = ContractKeys

    public let id: UUID
    public let kind: OrderFactKind
    public let label: String
    public let value: String
    public let carrier: String?
    /// Built by the server for a tracking number with a known carrier.
    public let trackingUrl: String?
    public let code: OrderCodeOut?
    public let documentId: UUID?

    public init(
        id: UUID, kind: OrderFactKind, label: String, value: String, carrier: String? = nil,
        trackingUrl: String? = nil, code: OrderCodeOut? = nil, documentId: UUID? = nil
    ) {
        self.id = id
        self.kind = kind
        self.label = label
        self.value = value
        self.carrier = carrier
        self.trackingUrl = trackingUrl
        self.code = code
        self.documentId = documentId
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

    /// A mail neither in the mailbox nor in glacier storage -- shown dimmed and not clickable.
    public var isGone: Bool { location == "gone" }
}

/// A readable attachment of one of the order's mails, or a file added to the order by hand.
public struct OrderDocumentOut: ContractModel, Codable, Sendable, Equatable, Identifiable {
    public static let schemaName = "OrderDocumentOut"
    public enum ContractKeys: String, CodingKey, CaseIterable {
        case id, source, messageId = "message_id", attachmentId = "attachment_id",
            fileId = "file_id", filename, contentType = "content_type", sizeBytes = "size_bytes",
            receivedAt = "received_at", pageCount = "page_count", method,
            barcodeCount = "barcode_count", downloadUrl = "download_url"
    }
    public typealias CodingKeys = ContractKeys

    public let id: UUID
    /// `"mail"` or `"file"`.
    public let source: String
    public let messageId: UUID?
    public let attachmentId: UUID?
    public let fileId: UUID?
    public let filename: String
    public let contentType: String
    public let sizeBytes: Int?
    public let receivedAt: Date
    public let pageCount: Int?
    public let method: String
    public let barcodeCount: Int
    /// A server path (with the `/api` prefix) serving the bytes; `nil` when the mail it belongs to
    /// is gone.
    public let downloadUrl: String?

    public init(
        id: UUID, source: String, messageId: UUID?, attachmentId: UUID?, fileId: UUID?, filename: String,
        contentType: String, sizeBytes: Int?, receivedAt: Date, pageCount: Int? = nil, method: String = "none",
        barcodeCount: Int = 0, downloadUrl: String?
    ) {
        self.id = id
        self.source = source
        self.messageId = messageId
        self.attachmentId = attachmentId
        self.fileId = fileId
        self.filename = filename
        self.contentType = contentType
        self.sizeBytes = sizeBytes
        self.receivedAt = receivedAt
        self.pageCount = pageCount
        self.method = method
        self.barcodeCount = barcodeCount
        self.downloadUrl = downloadUrl
    }

    public var isFile: Bool { source == "file" }
}

/// Where an added file stands: `"pending"` until the orders queue has placed it, then
/// `"attached"` (with its `orderId`) or `"failed"` (with `lastError`).
public struct OrderFileStatus: ContractModel, Codable, Sendable, Equatable {
    public static let schemaName = "OrderFileStatus"
    public enum ContractKeys: String, CodingKey, CaseIterable {
        case fileId = "file_id", orderId = "order_id", status, lastError = "last_error"
    }
    public typealias CodingKeys = ContractKeys

    public let fileId: UUID
    public let orderId: UUID?
    public let status: String
    public let lastError: String?

    public init(fileId: UUID, orderId: UUID?, status: String, lastError: String? = nil) {
        self.fileId = fileId
        self.orderId = orderId
        self.status = status
        self.lastError = lastError
    }

    public var isPending: Bool { status == "pending" }
    public var isAttached: Bool { status == "attached" }
    public var isFailed: Bool { status == "failed" }
}

public struct OrderDetail: ContractModel, Codable, Sendable, Equatable, Identifiable {
    public static let schemaName = "OrderDetail"
    public enum ContractKeys: String, CodingKey, CaseIterable {
        case id, merchant, subject, status, title, isOpen = "is_open", icon,
            summaryPreview = "summary_preview", firstMailAt = "first_mail_at",
            lastMailAt = "last_mail_at", mailCount = "mail_count", accountIds = "account_ids",
            textStale = "text_stale", updatedAt = "updated_at", isFavorite = "is_favorite",
            isSealed = "is_sealed", openSetBy = "open_set_by", expectedUntil = "expected_until",
            kind, kindSetBy = "kind_set_by", eventStart = "event_start", eventEnd = "event_end",
            timelineDate = "timeline_date", firstActivityAt = "first_activity_at",
            lastActivityAt = "last_activity_at", fileCount = "file_count", summary, facts, mails,
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
    /// Per-order flags a person sets; `@MVDefaulted` so a server that predates them still decodes.
    @MVDefaulted<MVDefaultFalse> public var isFavorite: Bool
    /// A sealed order takes no further mail.
    @MVDefaulted<MVDefaultFalse> public var isSealed: Bool
    /// Who decided the current `isOpen`: `"ai"`, `"user"` or `"auto"`.
    @MVDefaulted<MVDefaultOpenSetByAi> public var openSetBy: String
    /// `YYYY-MM-DD` of the last thing still expected; a date-only value, so kept as the wire string.
    public let expectedUntil: String?
    @MVDefaulted<MVDefaultOrderKind> public var kind: OrderKind
    @MVDefaulted<MVDefaultKindSetByAi> public var kindSetBy: String
    public let eventStart: String?
    public let eventEnd: String?
    public let timelineDate: String?
    public let firstActivityAt: Date?
    public let lastActivityAt: Date?
    @MVDefaulted<MVDefaultZero> public var fileCount: Int
    public let summary: String
    /// Typed key facts in the server's display order.
    @MVDefaulted<MVDefaultEmptyArray<OrderFactOut>> public var facts: [OrderFactOut]
    /// Oldest first -- the server's own order (`order_mails.received_at` ascending).
    public let mails: [OrderMailOut]
    /// Every readable attachment of the order's mails and every file added to it, newest first.
    @MVDefaulted<MVDefaultEmptyArray<OrderDocumentOut>> public var documents: [OrderDocumentOut]

    public init(
        id: UUID, merchant: String, subject: String, status: String, title: String, isOpen: Bool,
        icon: String, summaryPreview: String, firstMailAt: Date?, lastMailAt: Date?, mailCount: Int,
        accountIds: [UUID], textStale: Bool, updatedAt: Date, summary: String,
        facts: [OrderFactOut], mails: [OrderMailOut], documents: [OrderDocumentOut],
        isFavorite: Bool = false, isSealed: Bool = false, openSetBy: String = "ai",
        expectedUntil: String? = nil, kind: OrderKind = .order, kindSetBy: String = "ai",
        eventStart: String? = nil, eventEnd: String? = nil, timelineDate: String? = nil,
        firstActivityAt: Date? = nil, lastActivityAt: Date? = nil, fileCount: Int = 0
    ) {
        self.isFavorite = isFavorite
        self.isSealed = isSealed
        self.openSetBy = openSetBy
        self.expectedUntil = expectedUntil
        self.kind = kind
        self.kindSetBy = kindSetBy
        self.eventStart = eventStart
        self.eventEnd = eventEnd
        self.timelineDate = timelineDate
        self.firstActivityAt = firstActivityAt
        self.lastActivityAt = lastActivityAt
        self.fileCount = fileCount
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
        self.facts = facts
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
            textStale: textStale, updatedAt: updatedAt, isFavorite: isFavorite, isSealed: isSealed,
            openSetBy: openSetBy, expectedUntil: expectedUntil, kind: kind, kindSetBy: kindSetBy,
            eventStart: eventStart, eventEnd: eventEnd, timelineDate: timelineDate,
            firstActivityAt: firstActivityAt, lastActivityAt: lastActivityAt, fileCount: fileCount
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

/// A person's change to an order's flags; an omitted field is left alone, so every field is a
/// plain optional (a `nil` is simply not sent). Setting `isOpen` records the decision as theirs.
public struct OrderUpdateRequest: ContractModel, Codable, Sendable, Equatable {
    public static let schemaName = "OrderUpdateRequest"
    public enum ContractKeys: String, CodingKey, CaseIterable {
        case isFavorite = "is_favorite", isOpen = "is_open", isSealed = "is_sealed", kind
    }
    public typealias CodingKeys = ContractKeys

    public let isFavorite: Bool?
    public let isOpen: Bool?
    public let isSealed: Bool?
    /// A person's choice of kind; the model's rewrites leave it alone from then on.
    public let kind: OrderKind?

    public init(
        isFavorite: Bool? = nil, isOpen: Bool? = nil, isSealed: Bool? = nil, kind: OrderKind? = nil
    ) {
        self.isFavorite = isFavorite
        self.isOpen = isOpen
        self.isSealed = isSealed
        self.kind = kind
    }
}
