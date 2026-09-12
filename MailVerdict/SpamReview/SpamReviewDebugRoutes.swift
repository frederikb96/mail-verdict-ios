import MailVerdictKit

#if DEBUG

    /// `/spam-review/state` — the loaded count and whether more is waiting.
    enum SpamReviewDebugRoutes {
        static func register(into router: inout DebugRouter) {
            router.register("GET", "/spam-review/state") { _ in
                guard let snapshot = SpamReviewDebugReporter.shared.snapshot() else {
                    return .message("no SpamReviewStore has reported yet", status: 404)
                }
                return .encoding(snapshot)
            }
        }
    }

#endif
