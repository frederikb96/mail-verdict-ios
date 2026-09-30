import Foundation

/// The confirmation shown before a move actually lands on the glacier — the one Move-picker
/// target whose destination is not on the mail server at all, so the count and the consequence
/// both need saying before it happens. Shared by the list (swipe sheet, context menu, select
/// mode) and the reader's own Options "Move to…", which is what keeps the wording one string
/// rather than four.
public enum GlacierMoveWarning {
    public static func title(count: Int) -> String {
        count == 1 ? "Move to Glacier?" : "Move \(count) Messages to Glacier?"
    }

    public static func message(count: Int) -> String {
        let subject = count == 1 ? "This message" : "These \(count) messages"
        return
            "\(subject) will leave the mail server for good and live on only in MailVerdict. This cannot be undone."
    }
}

/// The confirmation shown before permanently deleting a message already in the glacier — it is
/// the only copy that exists, unlike an ordinary Trash message, which the mail server also still
/// holds until this same "Delete Forever" removes it there too. Shared by every surface Delete
/// Forever already reaches (swipe sheet, context menu, reader bottom bar and Options), row-level
/// and bulk alike. Empty Folder… does not reach it: it is deliberately not offered for the
/// glacier at all, since its own confirmation count comes from an endpoint that does not yet
/// resolve a glacier folder id.
public enum GlacierDeleteWarning {
    public static func message(count: Int) -> String {
        let subject =
            count == 1
            ? "This is the only copy of this message" : "These are the only copies of these \(count) messages"
        return "\(subject). Deleting \(count == 1 ? "it" : "them") is permanent and cannot be undone."
    }
}

/// The confirmation shown before Archive, Move to trash or an explicit Move actually restores a
/// glaciered message (or an entire selection sitting in the glacier) to the mail server -- the
/// reverse of `GlacierMoveWarning`, and never fired without it, the same way entering the glacier
/// needs its own confirmation. One wording, reused wherever such a restore can start: the row's
/// own swipe sheet and context menu, the reader's bottom bar, and the list's select-mode toolbar.
public enum GlacierRestoreWarning {
    public enum Action { case archive, trash, move }

    public static func title(action: Action, count: Int) -> String {
        switch action {
        case .archive: return count == 1 ? "Archive?" : "Archive \(count) Messages?"
        case .trash: return count == 1 ? "Move to Trash?" : "Move \(count) Messages to Trash?"
        case .move: return count == 1 ? "Move to This Folder?" : "Move \(count) Messages?"
        }
    }

    public static func confirmLabel(_ action: Action) -> String {
        switch action {
        case .archive: return "Archive"
        case .trash: return "Move to Trash"
        case .move: return "Move"
        }
    }

    public static func message(count: Int) -> String {
        let subject = count == 1 ? "This message" : "These \(count) messages"
        let verb = count == 1 ? "goes" : "go"
        let counts = count == 1 ? "counts" : "count"
        return "\(subject) \(verb) back onto the mail server and \(counts) toward your mailbox's storage again."
    }
}
