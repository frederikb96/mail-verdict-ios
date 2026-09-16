/// Every SF Symbol name this app uses for a MailVerdict-specific action or element. The IMAP
/// `\Flagged` bit is "Star" on iOS (`star`/`star.fill`, not `flag`/`flag.fill`) and stays
/// `{flag}`/`{unflag}` at the API layer, `Models/BulkAction.swift`'s `MVBulkAction` — only the
/// user-facing name and symbol change.
///
/// A plain `String` rather than `Image(systemName:)` directly: this package builds on Linux,
/// where `Image` does not exist.
public enum MVSymbols {
    public static let archive = "archivebox"
    public static let delete = "trash"
    public static let deleteForever = "trash.slash"
    public static let options = "ellipsis"
    public static let reply = "arrowshape.turn.up.left"
    public static let replyAll = "arrowshape.turn.up.left.2"
    public static let forward = "arrowshape.turn.up.right"
    public static let markRead = "envelope.open"
    public static let markUnread = "envelope.badge"
    public static let star = "star"
    public static let unstar = "star.slash"
    public static let starFilled = "star.fill"
    public static let moveTo = "folder"
    public static let moveToJunk = "xmark.bin"
    public static let notJunk = "tray.and.arrow.up"
    public static let confirmVerdict = "hand.thumbsup"
    public static let correctVerdict = "hand.thumbsdown"
    public static let findInMessage = "text.magnifyingglass"
    public static let remoteImages = "photo"
    public static let darkBackground = "moon"
    public static let lightBackground = "sun.max"
    public static let shareMessageFile = "square.and.arrow.up"
    public static let showInFolder = "folder.badge.gearshape"
    public static let compose = "square.and.pencil"
    public static let filterUnread = "line.3.horizontal.decrease.circle"
    public static let filterUnreadFilled = "line.3.horizontal.decrease.circle.fill"
    public static let groupByConversation = "rectangle.stack"
    public static let previousMessage = "chevron.up"
    public static let nextMessage = "chevron.down"
    public static let send = "arrow.up.circle.fill"
    public static let format = "textformat"
    public static let attach = "paperclip"
    public static let link = "link"
    public static let answeredMark = "arrowshape.turn.up.left.fill"
    public static let attachmentMark = "paperclip"
    public static let spamMark = "exclamationmark.shield.fill"
    /// A row whose last change the server refused.
    public static let actionFailed = "exclamationmark.circle.fill"
    public static let bell = "bell"
    public static let spamReview = "shield.lefthalf.filled"
    public static let accounts = "person.crop.circle"
    public static let settings = "gearshape"
    public static let unifiedViewDefault = "square.stack"
    public static let senderException = "envelope"
    public static let domainException = "globe"
    public static let device = "iphone"
    public static let nothingToReview = "checkmark.shield"
    public static let disclosureChevron = "chevron.right"

    /// Folder special-use icons, keyed by PostIMAP's own `special_use` string
    /// (`inbox`/`drafts`/`sent`/`archive`/`junk`/`trash`), with `folder` as the fallback for an
    /// ordinary or unrecognized one.
    public static func folderIcon(specialUse: String?) -> String {
        switch specialUse {
        case "inbox": return "tray"
        case "drafts": return "doc"
        case "sent": return "paperplane"
        case "archive": return "archivebox"
        case "junk": return "xmark.bin"
        case "trash": return "trash"
        default: return "folder"
        }
    }
}
