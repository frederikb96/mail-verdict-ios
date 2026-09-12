import MailVerdictKit

#if DEBUG

    /// `/mailboxes/state` — collapsed sections and the scroll anchor, read back without a
    /// screenshot so returning to this screen can be checked for the same position and
    /// collapse state it left. `MailboxesStore` reports into `MailboxesDebugReporter` itself,
    /// since this route's handler is a synchronous, non-isolated closure that cannot hop to the
    /// main actor to read the store directly.
    enum MailboxesDebugRoutes {
        /// Added to `DebugRoutes.featureRegistrars` in `MailVerdictApp.swift` — the one line that
        /// file actually changes for this screen.
        static func register(into router: inout DebugRouter) {
            router.register("GET", "/mailboxes/state") { _ in
                guard let snapshot = MailboxesDebugReporter.shared.snapshot() else {
                    return .message("no MailboxesStore has reported yet", status: 404)
                }
                return .encoding(snapshot)
            }
        }
    }

#endif
