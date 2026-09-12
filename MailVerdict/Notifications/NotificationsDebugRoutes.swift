import MailVerdictKit

#if DEBUG

    /// `/notifications/state` — the Mail and System tab counts.
    enum NotificationsDebugRoutes {
        static func register(into router: inout DebugRouter) {
            router.register("GET", "/notifications/state") { _ in
                guard let snapshot = NotificationsDebugReporter.shared.snapshot() else {
                    return .message("no NotificationsStore has reported yet", status: 404)
                }
                return .encoding(snapshot)
            }
        }
    }

#endif
