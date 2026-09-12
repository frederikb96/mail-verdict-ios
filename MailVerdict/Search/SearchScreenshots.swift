import MailVerdictKit

#if DEBUG

    /// Search's own screenshot entries.
    ///
    /// The fixture routes are registered on arrival (`prepare`), not when this array is built —
    /// see `MailboxesScreenshots`'s own note on why.
    enum SearchScreenshots {
        static let entries: [MVScreenshotEntry] = [
            MVScreenshotEntry(
                id: "search-with-results", destination: .route(.search(initialQuery: "invoice")),
                prepare: { _, _ in await loadFixtures() }
            )
        ]

        @MainActor
        private static func loadFixtures() async {
            MailboxesFixtures.registerIfNeeded()
            SearchFixtures.registerIfNeeded()
            guard let store = await poll({ SearchFixtures.activeStore }) else { return }
            await store.runSearch()
            if store.errorMessage != nil { await store.runSearch() }
        }

        /// Up to five seconds, checked every 50 ms — the screen's own `.task` sets
        /// `SearchFixtures.activeStore` only once its `init` has run, a moment after navigation.
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
