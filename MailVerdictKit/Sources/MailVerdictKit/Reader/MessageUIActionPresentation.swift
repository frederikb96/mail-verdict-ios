import Foundation

/// How each Options action reads and looks — one mapping for the reader's menu, the list's
/// context menu and the swipe sheet alike, so the three surfaces never label one action two ways.
/// Symbols come from `MVSymbols`.
extension MVMessageUIAction {

    /// `senderEmail`/`senderDomain` name the remote-images choices ("Always Load from …").
    public func title(senderEmail: String = "", senderDomain: String = "") -> String {
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
        case .alwaysLoadFromSender:
            return senderEmail.isEmpty ? "Always Load from Sender" : "Always Load from \(senderEmail)"
        case .alwaysLoadFromDomain:
            return senderDomain.isEmpty ? "Always Load from Domain" : "Always Load from @\(senderDomain)"
        case .darkBackground: return "Dark Background"
        case .lightBackground: return "Light Background"
        case .shareMessageFile: return "Share Message File…"
        case .showInFolder: return "Show in Folder"
        case .delete: return "Delete"
        case .deleteForever: return "Delete Forever"
        }
    }

    public var systemImage: String {
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

    /// The remote-images choices, shown together as one submenu.
    public var isRemoteImagesChoice: Bool {
        self == .loadImagesOnce || self == .alwaysLoadFromSender || self == .alwaysLoadFromDomain
    }

    /// The verdict group's heading — "Classified as spam by {model}" or "Classified as not spam".
    public static func verdictGroupTitle(_ verdict: MVMessageVerdictContext) -> String {
        guard verdict.isSpam else { return "Classified as not spam" }
        return verdict.modelUsed.map { "Classified as spam by \($0)" } ?? "Classified as spam"
    }
}
