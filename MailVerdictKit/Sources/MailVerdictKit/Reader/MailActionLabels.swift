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
}
