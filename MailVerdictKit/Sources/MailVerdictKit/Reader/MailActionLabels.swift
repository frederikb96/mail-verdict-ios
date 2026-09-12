import Foundation

/// The phrasing of an action's toasts — `UNDO_TOAST_LABELS` and `ACTION_LABELS` in the web's
/// `hooks/use-mails.ts`.
public enum MailActionLabels {

    /// The success toast an undoable action shows beside its Undo button; `nil` for an action with
    /// no compensating move (expunge) or one that already is the correction (not spam).
    public static func undoToast(for action: MVMessageAction) -> String? {
        switch action {
        case .trash: return "Moved to trash"
        case .archive: return "Archived"
        case .spam: return "Marked as spam"
        default: return nil
        }
    }

    /// The verb in "Could not {verb}: {reason}".
    public static func verb(for action: MVMessageAction) -> String {
        switch action {
        case .markRead: return "mark as read"
        case .markUnread: return "mark as unread"
        case .flag: return "star"
        case .unflag: return "unstar"
        case .move: return "move"
        case .archive: return "archive"
        case .trash: return "move to trash"
        case .expunge: return "delete forever"
        case .spam: return "mark as spam"
        case .notSpam: return "mark as not spam"
        case .keywordAdd: return "add keyword"
        case .keywordRemove: return "remove keyword"
        }
    }

    public static func failure(_ action: MVMessageAction, reason: String) -> String {
        "Could not \(verb(for: action)): \(reason)"
    }
}
