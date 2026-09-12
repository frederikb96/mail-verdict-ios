import Foundation

/// The last direction a person paged the reader in — which side `autoAdvanceTarget` tries first
/// after the current page is cleared by a destructive action.
public enum MVAutoAdvanceDirection: Sendable, Equatable {
    case older
    case newer
}

/// What an Undo tap replays: `POST /messages/{id}/action {move, target_folder_id: original}` for
/// each message — built at the moment the original (optimistic) action is applied, since that is
/// the only moment every message's *previous* folder is known.
public struct MVActionUndoPayload: Sendable, Equatable {
    /// `(messageId, folderId before the action)` pairs — a bulk action's own `sources` shape
    /// (`BulkActionResponse.sources`), reused here for a single action too so both paths build an
    /// Undo the same way.
    public let sources: [(messageId: UUID, originalFolderId: UUID)]
    public let action: MVBulkAction

    public init(sources: [(messageId: UUID, originalFolderId: UUID)], action: MVBulkAction) {
        self.sources = sources
        self.action = action
    }

    public static func == (lhs: MVActionUndoPayload, rhs: MVActionUndoPayload) -> Bool {
        lhs.action == rhs.action
            && lhs.sources.elementsEqual(rhs.sources) {
                $0.messageId == $1.messageId && $0.originalFolderId == $1.originalFolderId
            }
    }
}

/// Keeps the one id a person explicitly marked unread — `explicitlyUnreadMailIdAtom`'s port.
/// Reading the same message again marks it read as always; only this one id is exempt from the
/// reader's own "mark read on settle" rule, and only until something else marks it read or marks
/// a different message unread (there is only ever one such id at a time, the same as the web).
public actor MVExplicitUnreadTracker {
    private var messageId: UUID?

    public init() {}

    public func markExplicit(_ id: UUID) {
        messageId = id
    }

    public func clear() {
        messageId = nil
    }

    public func isExplicit(_ id: UUID) -> Bool {
        messageId == id
    }
}

/// The handful of rules every store doing optimistic single-message actions needs, kept here so
/// S1 and S2 apply the same ones rather than each re-deriving them.
public enum MailActionService {

    /// Which action a single `MVMessageUIAction` sends, and the target folder it needs (`nil`
    /// for an action `target_folder_id` never applies to, or when the caller has not resolved a
    /// destination yet — `.moveTo` is a picker, not a single fixed target).
    public static func bulkAction(for uiAction: MVMessageUIAction, targetFolderId: UUID? = nil) -> MVBulkAction? {
        switch uiAction {
        case .markRead: return .markRead
        case .markUnread: return .markUnread
        case .star: return .flag
        case .unstar: return .unflag
        case .archive: return .archive
        case .moveToJunk: return .spam
        case .notJunk: return .notSpam
        case .delete: return .trash
        case .deleteForever: return .expunge
        case .moveTo: return targetFolderId != nil ? .move : nil
        default: return nil
        }
    }

    /// After a destructive action clears the current reader page: the neighbour in the last
    /// navigated direction, falling back to the other side, or `nil` (pop to the list) if
    /// neither exists. Port of the web's `neighbourInCache`.
    public static func autoAdvanceTarget(
        neighbours: (older: UUID?, newer: UUID?), lastDirection: MVAutoAdvanceDirection
    ) -> UUID? {
        switch lastDirection {
        case .older: return neighbours.older ?? neighbours.newer
        case .newer: return neighbours.newer ?? neighbours.older
        }
    }
}
