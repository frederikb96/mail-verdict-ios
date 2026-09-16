import Foundation

/// What a list shows, as far as projecting intents over it needs to know.
public struct MVProjectionScope: Equatable, Sendable {
    /// The folders the list shows. A move into one keeps its row; a move anywhere else hides it.
    public var folderIds: Set<UUID>
    public var threaded: Bool
    /// The loaded window has more rows below / above it — a row put back past either end would
    /// claim a place the window has not loaded.
    public var hasOlder: Bool
    public var hasNewer: Bool

    public init(folderIds: Set<UUID>, threaded: Bool, hasOlder: Bool = false, hasNewer: Bool = false) {
        self.folderIds = folderIds
        self.threaded = threaded
        self.hasOlder = hasOlder
        self.hasNewer = hasNewer
    }
}

/// Server data with intents applied on top — the one reducer every list and the reader read
/// through, so no screen patches its own copy.
public enum MVIntentProjection {

    /// Whether `intent` applies over data read when the ledger stood at `baseSequence`: while
    /// outstanding and not undone; once done, only over a read that began before the server had
    /// it, since a later read already carries it; never once refused.
    public static func applies(_ intent: MVMailIntent, over baseSequence: Int) -> Bool {
        switch intent.state {
        case .pending, .sending: return !intent.undoRequested
        case .done: return (intent.settledSequence ?? .max) > baseSequence
        case .failed: return false
        }
    }

    public static func rows(
        _ base: [MessageSummary], applying intents: [MVMailIntent], baseSequence: Int, scope: MVProjectionScope
    ) -> [MessageSummary] {
        intents.reduce(base) { rows, intent in
            applies(intent, over: baseSequence) ? apply(intent, to: rows, scope: scope) : rows
        }
    }

    public static func message(
        _ message: MessageDetail, applying intents: [MVMailIntent], baseSequence: Int
    ) -> MessageDetail {
        var result = message
        for intent in intents where applies(intent, over: baseSequence) && intent.messageIds.contains(message.id) {
            switch intent.action {
            case .markRead: result.isSeen = true
            case .markUnread: result.isSeen = false
            case .flag: result.isFlagged = true
            case .unflag: result.isFlagged = false
            case .move, .archive, .trash, .expunge, .spam, .notSpam: break
            }
        }
        return result
    }

    static func apply(_ intent: MVMailIntent, to rows: [MessageSummary], scope: MVProjectionScope) -> [MessageSummary] {
        let ids = Set(intent.messageIds)
        if case .conversationRead = intent.delivery {
            return rows.map { ids.contains($0.id) ? $0.with(isSeen: true, unreadInThread: 0) : $0 }
        }
        guard intent.leavesFolder else {
            return rows.map { ids.contains($0.id) ? applying(intent.action, to: $0, threaded: scope.threaded) : $0 }
        }
        guard intent.action == .move, let target = intent.targetFolderId, scope.folderIds.contains(target) else {
            return rows.filter { !ids.contains($0.id) }
        }
        var result = rows.map { ids.contains($0.id) ? $0.with(folderId: target) : $0 }
        for snapshot in intent.snapshots
        where ids.contains(snapshot.id) && !result.contains(where: { $0.id == snapshot.id }) {
            let row = snapshot.with(folderId: target)
            let position = result.firstIndex { MVMailListWindow.sitsAbove(row, $0) } ?? result.count
            if position == result.count && scope.hasOlder { continue }
            if position == 0 && scope.hasNewer { continue }
            result.insert(row, at: position)
        }
        return result
    }

    /// Read and star changes on one row. Grouped by conversation, the row's unread count moves
    /// with its own message — idempotent, so applying it over a read that already carries it
    /// changes nothing.
    public static func applying(_ action: MVBulkAction, to row: MessageSummary, threaded: Bool) -> MessageSummary {
        switch action {
        case .markRead:
            let unread = threaded ? max((row.unreadInThread ?? 0) - (row.isSeen ? 0 : 1), 0) : row.unreadInThread
            return row.with(isSeen: true, unreadInThread: unread)
        case .markUnread:
            let unread = threaded ? (row.unreadInThread ?? 0) + (row.isSeen ? 1 : 0) : row.unreadInThread
            return row.with(isSeen: false, unreadInThread: unread)
        case .flag: return row.with(isFlagged: true)
        case .unflag: return row.with(isFlagged: false)
        case .move, .archive, .trash, .expunge, .spam, .notSpam: return row
        }
    }
}
