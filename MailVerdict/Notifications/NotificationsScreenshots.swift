import MailVerdictKit

#if DEBUG

    /// The bell's own screenshot entries.
    ///
    /// The fixture routes are registered on arrival (`prepare`), not when this array is built —
    /// see `MailboxesScreenshots`'s own note on why.
    enum NotificationsScreenshots {
        static let entries: [MVScreenshotEntry] = [
            MVScreenshotEntry(
                id: "notifications-mail-tab", destination: .route(.notifications),
                prepare: { _, _ in await loadFixtures() }
            )
        ]

        @MainActor
        private static func loadFixtures() async {
            NotificationsFixtures.registerIfNeeded()
            guard let store = await poll({ NotificationsFixtures.activeStore }) else { return }
            await store.load()
            if store.errorMessage != nil { await store.load() }
        }

        /// Up to five seconds, checked every 50 ms.
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
