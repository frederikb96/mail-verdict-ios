import MailVerdictKit
import Observation

/// Holds a shortcut's target until the signed-in shell can act on it: an intent can run before
/// there is a navigation stack, or even a signed-in user.
@MainActor
@Observable
final class ShortcutInbox {
    static let shared = ShortcutInbox()

    var pending: MVShortcutTarget?

    private init() {}
}
