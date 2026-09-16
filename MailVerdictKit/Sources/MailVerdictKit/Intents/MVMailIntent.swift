import Foundation

/// One mail action a person took — read, star, move, archive, trash, junk — held until the server
/// has it, and persisted so it survives a relaunch. What a screen shows is the server's data with
/// every intent still outstanding applied on top (`MVIntentProjection`), so a read landing while a
/// request is out can never undo on screen what the person just did.
public struct MVMailIntent: Codable, Sendable, Equatable, Identifiable {

    /// How the intent reaches the server.
    public enum Delivery: Codable, Sendable, Equatable {
        /// `POST /messages/{id}/action` for the one message named.
        case message
        /// `POST /accounts/{id}/messages/bulk-action` with the ids named.
        case bulk(expandThreads: Bool)
        /// Every unread message of the named message's conversation within `folderIds`, resolved
        /// from the thread at send time and marked read in one bulk request.
        case conversationRead(folderIds: [UUID])
    }

    public enum Phase: String, Codable, Sendable, Equatable {
        /// Waiting its turn, for the network, for a retry, or for the person to confirm it.
        case pending
        /// The request is out.
        case sending
        /// The server accepted it.
        case done
        /// The server refused it, or it kept failing. Kept, unapplied, until retried or retired.
        case failed
    }

    /// Also the request's idempotency key: every retry, a relaunch's included, is the same request
    /// to the server.
    public let id: UUID
    public let accountId: UUID
    public let action: MVBulkAction
    public let targetFolderId: UUID?
    public let messageIds: [UUID]
    public let delivery: Delivery
    /// The folder each message was in when the action was taken — where Undo moves it back to.
    public internal(set) var originFolderIds: [UUID: UUID]
    /// The list rows the messages had, when a list held them: an undone move puts these back.
    public internal(set) var snapshots: [MessageSummary]
    /// The intent this one undoes.
    public let undoes: UUID?
    public let createdAt: Date
    public internal(set) var state: Phase
    public internal(set) var attempts: Int
    public internal(set) var nextAttemptAt: Date?
    public internal(set) var lastError: String?
    /// `MVIntentLedger.sequence` when this became `done` or `failed`.
    public internal(set) var settledSequence: Int?
    public internal(set) var settledAt: Date?
    /// Every message the server reports having moved — an expanded conversation names more than
    /// `messageIds` does.
    public internal(set) var movedSources: [BulkActionSource]
    /// A conversation read's unread messages, as resolved on its first attempt. Every retry sends
    /// exactly these, since the server refuses a repeated idempotency key with a different body.
    public internal(set) var resolvedMessageIds: [UUID]?
    /// An earlier attempt may have reached the server without an answer coming back. Before
    /// sending again, the ledger looks at the messages themselves.
    public internal(set) var mayHaveLanded: Bool
    /// Undone while its request was out: it no longer applies, and is reversed once the request
    /// settles.
    public internal(set) var undoRequested: Bool
    /// Past `MVIntentLedger.Timing.pendingExpiry` unsent: held until the person sends or discards it.
    public internal(set) var awaitingConfirmation: Bool
    /// The person chose to send it after all.
    public internal(set) var sendConfirmed: Bool
    /// Where the server filed each message — the folder an undo expects to find it in.
    public internal(set) var filedFolderIds: [UUID: UUID]
    /// For a bulk action expanding conversations: the newest `mirrored_at` among the rows acted on,
    /// so replies that arrive before a late send are not swept along.
    public let seenThrough: Date?

    init(request: MVIntentRequest, id: UUID, undoes: UUID?, createdAt: Date) {
        self.id = id
        self.accountId = request.accountId
        self.action = request.action
        self.targetFolderId = request.targetFolderId
        self.messageIds = request.messageIds
        self.delivery = request.delivery
        self.originFolderIds = request.originFolderIds
        self.snapshots = request.snapshots
        self.undoes = undoes
        self.createdAt = createdAt
        self.state = .pending
        self.attempts = 0
        self.movedSources = []
        self.mayHaveLanded = false
        self.undoRequested = false
        self.awaitingConfirmation = false
        self.sendConfirmed = false
        self.filedFolderIds = [:]
        self.seenThrough = request.seenThrough
    }

    /// Everything but the identity and the action itself may be missing from a record an older or
    /// newer build wrote, and a snapshot that no longer decodes is dropped rather than the intent.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        accountId = try container.decode(UUID.self, forKey: .accountId)
        action = try container.decode(MVBulkAction.self, forKey: .action)
        targetFolderId = try container.decodeIfPresent(UUID.self, forKey: .targetFolderId)
        messageIds = try container.decode([UUID].self, forKey: .messageIds)
        delivery = try container.decode(Delivery.self, forKey: .delivery)
        originFolderIds = (try? container.decodeIfPresent([UUID: UUID].self, forKey: .originFolderIds)) ?? [:]
        snapshots = (try? container.decodeIfPresent([MessageSummary].self, forKey: .snapshots)) ?? []
        undoes = try container.decodeIfPresent(UUID.self, forKey: .undoes)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        state = try container.decode(Phase.self, forKey: .state)
        attempts = try container.decodeIfPresent(Int.self, forKey: .attempts) ?? 0
        nextAttemptAt = try container.decodeIfPresent(Date.self, forKey: .nextAttemptAt)
        lastError = try container.decodeIfPresent(String.self, forKey: .lastError)
        settledSequence = try container.decodeIfPresent(Int.self, forKey: .settledSequence)
        settledAt = try container.decodeIfPresent(Date.self, forKey: .settledAt)
        movedSources = (try? container.decodeIfPresent([BulkActionSource].self, forKey: .movedSources)) ?? []
        resolvedMessageIds = try container.decodeIfPresent([UUID].self, forKey: .resolvedMessageIds)
        mayHaveLanded = try container.decodeIfPresent(Bool.self, forKey: .mayHaveLanded) ?? false
        undoRequested = try container.decodeIfPresent(Bool.self, forKey: .undoRequested) ?? false
        awaitingConfirmation = try container.decodeIfPresent(Bool.self, forKey: .awaitingConfirmation) ?? false
        sendConfirmed = try container.decodeIfPresent(Bool.self, forKey: .sendConfirmed) ?? false
        filedFolderIds = (try? container.decodeIfPresent([UUID: UUID].self, forKey: .filedFolderIds)) ?? [:]
        seenThrough = try container.decodeIfPresent(Date.self, forKey: .seenThrough)
    }

    /// Outstanding: not yet known to the server.
    public var isOpen: Bool { state == .pending || state == .sending }

    public var leavesFolder: Bool { action.removesFromList }

    /// The folder each message is expected in when sent, for actions that must not follow a
    /// message somewhere it has been filed since. Read and star changes follow it anywhere.
    var expectedFolderIds: [UUID: UUID]? {
        guard leavesFolder || action == .expunge, !originFolderIds.isEmpty else { return nil }
        return originFolderIds.filter { messageIds.contains($0.key) }
    }

    /// The messages this intent's request can touch — ordering holds later intents naming any of
    /// them back until this one is done.
    var touchedMessageIds: [UUID] { messageIds + (resolvedMessageIds ?? []) }
}

/// What a surface asks the ledger to do — an intent before it has an identity or a state.
public struct MVIntentRequest: Sendable, Equatable {
    public var accountId: UUID
    public var action: MVBulkAction
    public var targetFolderId: UUID?
    public var messageIds: [UUID]
    public var delivery: MVMailIntent.Delivery
    public var originFolderIds: [UUID: UUID]
    public var snapshots: [MessageSummary]
    public var seenThrough: Date?

    public init(
        accountId: UUID, action: MVBulkAction, targetFolderId: UUID? = nil, messageIds: [UUID],
        delivery: MVMailIntent.Delivery = .message, originFolderIds: [UUID: UUID] = [:],
        snapshots: [MessageSummary] = [], seenThrough: Date? = nil
    ) {
        self.accountId = accountId
        self.action = action
        self.targetFolderId = targetFolderId
        self.messageIds = messageIds
        self.delivery = delivery
        self.originFolderIds = originFolderIds
        self.snapshots = snapshots
        self.seenThrough = seenThrough
    }
}

/// How an intent ended, for a caller that waits on it.
public enum MVIntentOutcome: Sendable, Equatable {
    /// `affectedCount` is the bulk endpoint's own count; `nil` for a single-message action.
    case done(affectedCount: Int?, sources: [BulkActionSource])
    /// The message no longer exists on the server.
    case gone
    case failed(String)
    /// Undone or discarded before the server had it.
    case cancelled
    /// The messages were no longer where the action expected them; nothing was written.
    case notApplied
}

/// What a row or the reader shows for the intents naming a message.
public enum MVIntentRowState: Sendable, Equatable {
    case none
    /// A change has been waiting longer than a moment — slow, offline, retrying, or held for
    /// the person to confirm.
    case waiting
    /// The server refused a change, or it kept failing.
    case failed
}
