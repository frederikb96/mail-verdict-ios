import Foundation

public enum NotificationsSupport {

    /// The alert kind that is new mail. Every other kind is a system notification, listed under
    /// System — port of the web's `lib/bell-badge.ts`.
    public static let mailAlertKind = "mail"

    public static func isMailAlertKind(_ kind: String) -> Bool {
        kind == mailAlertKind
    }

    /// Port of `notification-bell.tsx`'s `ACTION_LABELS` — what a PostIMAP write-failure action
    /// reads as in the System tab ("{label} failed").
    public static func actionLabel(for action: String) -> String {
        switch action {
        case "flag_add": return "Setting a flag"
        case "flag_remove": return "Clearing a flag"
        case "move": return "Moving a message"
        case "delete": return "Deleting a message"
        case "send": return "Sending a message"
        case "draft": return "Saving a draft"
        default: return action
        }
    }
}
