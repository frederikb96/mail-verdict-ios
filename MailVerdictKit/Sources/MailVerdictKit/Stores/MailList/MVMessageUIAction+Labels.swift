import Foundation

extension MVBulkAction {
    /// Lower-case phrasing for "Could not …" and "Applying … to N messages" (port of the web's
    /// `ACTION_LABELS`).
    public var phrase: String {
        switch self {
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
        }
    }

    /// The success toast of an undoable single-message action (the web's `UNDO_TOAST_LABELS`).
    var undoToastTitle: String? {
        switch self {
        case .trash: return "Moved to trash"
        case .archive: return "Archived"
        case .spam: return "Marked as spam"
        default: return nil
        }
    }

    /// The same, for a bulk action's "N messages …" toast (the web's `BULK_UNDO_PHRASING`).
    var bulkUndoPhrase: String? {
        switch self {
        case .trash: return "moved to trash"
        case .archive: return "archived"
        case .spam: return "marked as spam"
        default: return nil
        }
    }

    /// The action that puts read or star state back; `nil` for one that moves the message.
    public var inverse: MVBulkAction? {
        switch self {
        case .markRead: return .markUnread
        case .markUnread: return .markRead
        case .flag: return .unflag
        case .unflag: return .flag
        case .move, .archive, .trash, .expunge, .spam, .notSpam: return nil
        }
    }

    /// Actions that take a message out of the folder it was shown in.
    var removesFromList: Bool {
        switch self {
        case .move, .archive, .trash, .expunge, .spam, .notSpam: return true
        case .markRead, .markUnread, .flag, .unflag: return false
        }
    }
}
