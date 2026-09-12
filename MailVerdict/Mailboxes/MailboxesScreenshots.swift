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
            MVScreenshotEntry(id: "mailboxes", destination: .root, prepare: { _, _ in await loadFixtures() })
        ]

        @MainActor
        private static func loadFixtures() async {
            MailboxesFixtures.registerIfNeeded()
            guard let store = await poll({ MailboxesFixtures.activeStore }) else { return }
            await store.load()
            if store.loadError != nil { await store.load() }
        }

        /// Up to five seconds, checked every 50 ms — Mailboxes is the root screen, mounted before
        /// any navigation, so its own `.task` (which sets `MailboxesFixtures.activeStore`) races
        /// this entry's `prepare` with no ordering guarantee between them.
        @MainActor
        private static func poll<Value>(_ probe: @MainActor () -> Value?) async -> Value? {
            for _ in 0..<100 {
                if let value = probe() { return value }
                try? await Task.sleep(for: .milliseconds(50))
            }
            return nil
        }
    }

#endif
