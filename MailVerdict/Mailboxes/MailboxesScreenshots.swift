import MailVerdictKit

#if DEBUG

    /// Mailboxes' own screenshot entries.
    ///
    /// The fixture routes are registered on arrival (`prepare`), not when this array is built —
    /// every feature's list is evaluated at launch, so routes registered there would answer
    /// other screens' requests on the same paths (`/api/accounts`, most concretely) in every
    /// screenshot launch, not only this one's.
    enum MailboxesScreenshots {
        static let entries: [MVScreenshotEntry] = [
            MVScreenshotEntry(
                id: "mailboxes-fixture-row", destination: .root, prepare: { _, _ in await loadFixtures() })
        ]

        @MainActor
        private static func loadFixtures() async {
            MailboxesFixtures.registerIfNeeded()
            guard let store = MailboxesFixtures.activeStore else { return }
            // The screen's own `.task` may already have tried (and failed, with no fixture
            // routes yet registered) by the time this runs — reload once now that they exist.
            await store.load()
            if store.loadError != nil { await store.load() }
        }
    }

#endif
