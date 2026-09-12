import Foundation

extension MVMessageUIAction {
    /// The user-facing label — one wording per action across the swipe sheet, the context menu
    /// and the reader's Options menu.
    public var title: String {
        switch self {
        case .reply: return "Reply"
        case .replyAll: return "Reply All"
        case .forward: return "Forward"
        case .confirmVerdict: return "Confirm Verdict"
        case .correctVerdict: return "Correct Verdict"
        case .markRead: return "Mark as Read"
        case .markUnread: return "Mark as Unread"
        case .star: return "Star"
        case .unstar: return "Unstar"
        case .moveTo: return "Move to…"
        case .moveToJunk: return "Move to Junk"
        case .notJunk: return "Not Junk"
        case .archive: return "Archive"
        case .findInMessage: return "Find in Message"
        case .loadImagesOnce: return "Load for This Message"
        case .alwaysLoadFromSender: return "Always Load from Sender"
        case .alwaysLoadFromDomain: return "Always Load from Domain"
        case .darkBackground: return "Dark Background"
        case .lightBackground: return "Light Background"
        case .shareMessageFile: return "Share Message File…"
        case .showInFolder: return "Show in Folder"
        case .delete: return "Delete"
        case .deleteForever: return "Delete Forever"
        }
    }

    /// The SF Symbol for the action (`Theme/MVSymbols.swift` owns the names).
    public var symbol: String {
        switch self {
        case .reply: return MVSymbols.reply
        case .replyAll: return MVSymbols.replyAll
        case .forward: return MVSymbols.forward
        case .confirmVerdict: return MVSymbols.confirmVerdict
        case .correctVerdict: return MVSymbols.correctVerdict
        case .markRead: return MVSymbols.markRead
        case .markUnread: return MVSymbols.markUnread
        case .star: return MVSymbols.star
        case .unstar: return MVSymbols.unstar
        case .moveTo: return MVSymbols.moveTo
        case .moveToJunk: return MVSymbols.moveToJunk
        case .notJunk: return MVSymbols.notJunk
        case .archive: return MVSymbols.archive
        case .findInMessage: return MVSymbols.findInMessage
        case .loadImagesOnce, .alwaysLoadFromSender, .alwaysLoadFromDomain: return MVSymbols.remoteImages
        case .darkBackground: return MVSymbols.darkBackground
        case .lightBackground: return MVSymbols.lightBackground
        case .shareMessageFile: return MVSymbols.shareMessageFile
        case .showInFolder: return MVSymbols.showInFolder
        case .delete: return MVSymbols.delete
        case .deleteForever: return MVSymbols.deleteForever
        }
    }

    public var isDestructive: Bool {
        self == .delete || self == .deleteForever
    }
}

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

    /// Actions that take a message out of the folder it was shown in.
    var removesFromList: Bool {
        switch self {
        case .move, .archive, .trash, .expunge, .spam, .notSpam: return true
        case .markRead, .markUnread, .flag, .unflag: return false
        }
    }
}
