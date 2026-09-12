import Foundation
import MailVerdictKit
import PushEnvelope

/// Where tapping a notification leads.
public enum PushTapTarget: Sendable, Equatable {
    /// Opened through `MVMessagePlaceResolver`, like a bell row.
    case message(UUID)
    /// A system alert (a stalled outbox, say): the Notifications screen lists it with context.
    case notifications
    /// A mail alert that names no message — the Mailboxes overview.
    case mailboxes

    /// From the string pairs the extension wrote into the notification's `userInfo`.
    public init(userInfo: [String: String]) {
        let kind = userInfo[PushNotificationKeys.kind] ?? PushNotificationKeys.mailKind
        guard kind == PushNotificationKeys.mailKind else {
            self = .notifications
            return
        }
        if let messageId = userInfo[PushNotificationKeys.messageId].flatMap(UUID.init(uuidString:)) {
            self = .message(messageId)
        } else {
            self = .mailboxes
        }
    }
}

public enum PushPresentation {
    /// Whether a notification arriving while the app is in front shows a banner. Not when the
    /// person is already reading that very message — the banner would announce what is on screen.
    public static func shouldPresent(messageId: UUID?, navigationPath: [Route]) -> Bool {
        guard let messageId, case .reader(let context)? = navigationPath.last else { return true }
        return context.messageId != messageId
    }
}
