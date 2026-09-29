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
/// Forever already reaches (swipe sheet, context menu, reader bottom bar and Options), so the
/// wording is one string rather than several.
public enum GlacierDeleteWarning {
    public static let message =
        "This is the only copy of this message. Deleting it is permanent and cannot be undone."
}
