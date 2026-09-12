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
