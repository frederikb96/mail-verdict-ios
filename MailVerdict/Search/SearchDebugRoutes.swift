import MailVerdictKit

#if DEBUG

    /// `/search/state` — mode, query, result count and the rendering state, read back without a
    /// screenshot.
    enum SearchDebugRoutes {
        static func register(into router: inout DebugRouter) {
            router.register("GET", "/search/state") { _ in
                guard let snapshot = SearchDebugReporter.shared.snapshot() else {
                    return .message("no SearchStore has reported yet", status: 404)
                }
                return .encoding(snapshot)
            }
        }
    }

#endif
