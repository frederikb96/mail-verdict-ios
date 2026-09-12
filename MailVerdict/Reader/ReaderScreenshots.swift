#if DEBUG

    import MailVerdictKit

    /// The reader's screenshot entries, all on the fixture list (`ReaderFixtures`). Each waits
    /// for its page to finish loading before it reports ready, so the sweep never captures the
    /// loading placeholder.
    enum ReaderScreenshots {
        private static let conversation = Route.reader(
            ReaderFixtures.context(opening: ReaderFixtures.conversationRowId))

        static let entries: [MVScreenshotEntry] = [
            MVScreenshotEntry(id: "reader-default", destination: .route(conversation)) { _, _ in
                await ReaderDebugHook.waitUntilLoaded()
            },
            MVScreenshotEntry(id: "reader-zoomed", destination: .route(conversation)) { _, _ in
                await ReaderDebugHook.waitUntilLoaded()
                ReaderDebugHook.active?.zoomCurrentPage(to: 2)
                try? await Task.sleep(nanoseconds: 300_000_000)
            },
            // A system menu cannot be opened without a touch, so this shows the menu's own
            // content in a sheet — the same groups, in the same order.
            MVScreenshotEntry(id: "reader-options", destination: .route(conversation)) { _, _ in
                await ReaderDebugHook.waitUntilLoaded()
                ReaderDebugHook.active?.showOptionsPreview()
                try? await Task.sleep(nanoseconds: 800_000_000)
            },
            MVScreenshotEntry(
                id: "reader-invitation",
                destination: .route(.reader(ReaderFixtures.context(opening: ReaderFixtures.invitationRowId)))
            ) { _, _ in
                await ReaderDebugHook.waitUntilLoaded(invitationCard: true)
            },
            MVScreenshotEntry(
                id: "reader-invitation-review",
                destination: .route(.reader(ReaderFixtures.context(opening: ReaderFixtures.reviewRowId)))
            ) { _, _ in
                await ReaderDebugHook.waitUntilLoaded(invitationCard: true)
            },
        ]
    }

#endif
