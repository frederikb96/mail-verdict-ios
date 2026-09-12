#if DEBUG

    import Foundation
    import MailVerdictKit

    /// `/reader/state`: the reader on screen as the app itself sees it — the current row and its
    /// neighbours, the page's zoom, whether the pager can scroll, the find count, and the page's
    /// content width against its own width (equal at rest zoom when a wide newsletter was fitted).
    enum ReaderDebugRoutes {
        static let register: @Sendable (inout DebugRouter) -> Void = { router in
            router.register("GET", "/reader/state") { _ in
                // The bridge answers on its own queue; the reader lives on the main thread.
                let state = DispatchQueue.main.sync {
                    MainActor.assumeIsolated { ReaderDebugHook.active?.debugState() }
                }
                guard let state else { return .message("no reader on screen", status: 404) }
                return .encoding(state)
            }
        }
    }

    struct ReaderDebugState: Codable, Sendable {
        let currentId: String
        let olderId: String?
        let newerId: String?
        let title: String?
        let zoomScale: Double
        let pagerScrollEnabled: Bool
        let findResultCount: Int
        let pageLoaded: Bool
        let contentWidth: Double
        let boundsWidth: Double
    }

    /// The reader currently on screen, for the debug bridge and the screenshot sweep.
    @MainActor
    enum ReaderDebugHook {
        static weak var active: ReaderViewController?

        /// Waits until the current page shows its conversation, has actually painted a frame
        /// (not merely finished navigation — see `MessagePageView.debugIsPainted`), and, when
        /// asked, its invitation card, read from the page's own document. `false` means the
        /// budget ran out with the page still not genuinely ready; the caller must not report
        /// readiness in that case; see `ReaderScreenshots`.
        static func waitUntilLoaded(invitationCard: Bool = false) async -> Bool {
            for _ in 0..<100 {
                if let reader = active, reader.isCurrentPageLoaded, await reader.currentPagePainted() {
                    var cardShown = true
                    if invitationCard {
                        cardShown = await reader.showsInvitationCard()
                    }
                    if cardShown {
                        // The page swaps a late block in on its next frame.
                        try? await Task.sleep(nanoseconds: 500_000_000)
                        return true
                    }
                }
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
            return false
        }
    }

#endif
