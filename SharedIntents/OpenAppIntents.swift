import AppIntents
import Foundation
import MailVerdictKit

// Compiled into the app and into the controls extension. A control that opens the app runs its
// intent in the app's process only when the app holds the very same type; with the intent in the
// extension alone, tapping the control fails without ever bringing the app forward.

/// Every action here brings the app to the front and parks where it should land, so a shortcut built
/// from one is one tap to that screen.
@MainActor
func land(on target: MVShortcutTarget) -> some IntentResult {
    ShortcutInbox.shared.pending = target
    return .result()
}

struct NewMessageIntent: AppIntent {
    static var title: LocalizedStringResource { "New Message" }
    static var description: IntentDescription { IntentDescription("Start a new message in MailVerdict.") }
    static var openAppWhenRun: Bool { true }

    @MainActor
    func perform() async throws -> some IntentResult {
        land(on: .newMessage)
    }
}

struct OpenOpenTicketsIntent: AppIntent {
    static var title: LocalizedStringResource { "Open Tickets" }
    static var description: IntentDescription {
        IntentDescription("Show only the tickets still open, on the timeline at today.")
    }
    static var openAppWhenRun: Bool { true }

    @MainActor
    func perform() async throws -> some IntentResult {
        land(on: .orders(OrderViewState(kind: .tickets, open: true)))
    }
}
