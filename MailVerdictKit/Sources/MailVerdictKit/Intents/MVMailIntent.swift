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
        /// Waiting its turn, for the network, or for a retry.
        case pending
        /// The request is out.
        case sending
        /// The server accepted it.
        case done
        /// The server refused it. Kept, unapplied, until retried or retired.
        case failed
    }

    /// Stable across every retry, a relaunch's included.
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
    }

    /// Outstanding: not yet known to the server.
    public var isOpen: Bool { state == .pending || state == .sending }

    public var leavesFolder: Bool { action.removesFromList }
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

    public init(
        accountId: UUID, action: MVBulkAction, targetFolderId: UUID? = nil, messageIds: [UUID],
        delivery: MVMailIntent.Delivery = .message, originFolderIds: [UUID: UUID] = [:],
        snapshots: [MessageSummary] = []
    ) {
        self.accountId = accountId
        self.action = action
        self.targetFolderId = targetFolderId
        self.messageIds = messageIds
        self.delivery = delivery
        self.originFolderIds = originFolderIds
        self.snapshots = snapshots
    }
}

/// How an intent ended, for a caller that waits on it.
public enum MVIntentOutcome: Sendable, Equatable {
    /// `affectedCount` is the bulk endpoint's own count; `nil` for a single-message action.
    case done(affectedCount: Int?, sources: [BulkActionSource])
    /// The message no longer exists on the server.
    case gone
    case failed(String)
    /// Undone before it was ever sent.
    case cancelled
}

/// What a row or the reader shows for the intents naming a message.
public enum MVIntentRowState: Sendable, Equatable {
    case none
    /// A change has been waiting longer than a moment — slow, offline or retrying.
    case waiting
    /// The server refused a change.
    case failed
}
