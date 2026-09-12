#if DEBUG

    import MailVerdictKit

    /// The reader's screenshot entries, all on the fixture list (`ReaderFixtures`). Each waits
    /// for its page to finish loading before it reports ready, so the sweep never captures the
    /// loading placeholder.
    enum ReaderScreenshots {
        private static let conversation = Route.reader(
            ReaderFixtures.context(opening: ReaderFixtures.conversationRowId))

        /// A genuine timeout means the page never became what it claims to be — hanging here,
        /// rather than returning, is what keeps `screenshotReady` from ever reporting this
        /// screen ready: the sweep's own poll of `/screen/current` then times out and fails the
        /// run honestly, instead of publishing a screenshot of whatever is actually on screen.
        private static func neverReady() async -> Never {
            while true { try? await Task.sleep(nanoseconds: 60 * 60 * 1_000_000_000) }
        }

        static let entries: [MVScreenshotEntry] = [
            MVScreenshotEntry(id: "reader-default", destination: .route(conversation)) { _, _ in
                guard await ReaderDebugHook.waitUntilLoaded() else { return await neverReady() }
            },
            MVScreenshotEntry(id: "reader-zoomed", destination: .route(conversation)) { _, _ in
                guard await ReaderDebugHook.waitUntilLoaded() else { return await neverReady() }
                ReaderDebugHook.active?.zoomCurrentPage(to: 2)
                try? await Task.sleep(nanoseconds: 300_000_000)
                guard (ReaderDebugHook.active?.currentZoomScale ?? 0) >= 1.5 else { return await neverReady() }
            },
            // A system menu cannot be opened without a touch, so this shows the menu's own
            // content in a sheet — the same groups, in the same order.
            MVScreenshotEntry(id: "reader-options", destination: .route(conversation)) { _, _ in
                guard await ReaderDebugHook.waitUntilLoaded() else { return await neverReady() }
                ReaderDebugHook.active?.showOptionsPreview()
                try? await Task.sleep(nanoseconds: 800_000_000)
            },
            MVScreenshotEntry(
                id: "reader-invitation",
                destination: .route(.reader(ReaderFixtures.context(opening: ReaderFixtures.invitationRowId)))
            ) { _, _ in
                guard await ReaderDebugHook.waitUntilLoaded(invitationCard: true) else { return await neverReady() }
            },
            MVScreenshotEntry(
                id: "reader-invitation-review",
                destination: .route(.reader(ReaderFixtures.context(opening: ReaderFixtures.reviewRowId)))
            ) { _, _ in
                guard await ReaderDebugHook.waitUntilLoaded(invitationCard: true) else { return await neverReady() }
            },
        ]
    }

#endif
