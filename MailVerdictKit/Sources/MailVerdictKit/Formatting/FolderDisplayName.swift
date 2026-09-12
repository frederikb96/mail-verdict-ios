import Foundation

/// The name a folder renders with (port of the web's `lib/folders.ts`): an explicit display
/// name first, then a role label for a recognised special-use folder — so a server's raw
/// "INBOX" or "Gelöschte Elemente" never leaks into the interface — then the raw server name.
public func folderDisplayName(imapName: String, displayName: String?, specialUse: String?) -> String {
    if let displayName, !displayName.isEmpty { return displayName }
    switch specialUse {
    case "inbox": return "Inbox"
    case "drafts": return "Drafts"
    case "sent": return "Sent"
    case "archive": return "Archive"
    case "junk": return "Junk"
    case "trash": return "Trash"
    default: return imapName
    }
}
