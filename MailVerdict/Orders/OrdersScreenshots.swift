import MailVerdictKit

#if DEBUG

    /// Orders & tickets' own screenshot entries: the list with content, its empty state, its
    /// loading state, and a detail with mails and a document.
    ///
    /// The fixture routes are registered on arrival (`prepare`), not when this array is built --
    /// see `MailboxesScreenshots`'s own note on why.
    enum OrdersScreenshots {
        static let entries: [MVScreenshotEntry] = [
            MVScreenshotEntry(id: "orders-list", destination: .route(.orders), prepare: { _, _ in await loadList() }),
            MVScreenshotEntry(
                id: "orders-list-empty", destination: .route(.orders), prepare: { _, _ in await loadEmptyList() }),
            MVScreenshotEntry(
                id: "orders-list-loading", destination: .route(.orders), prepare: { _, _ in await showLoadingList() }),
            MVScreenshotEntry(
                id: "order-detail", destination: .route(.order(OrdersFixtures.packageOrderId)),
                prepare: { _, _ in await loadDetail() }
            ),
        ]

        @MainActor
        private static func loadList() async {
            OrdersFixtures.registerList()
            guard let store = await poll({ OrdersFixtures.activeListStore }) else { return }
            await settle(store)
        }

        @MainActor
        private static func loadEmptyList() async {
            OrdersFixtures.registerEmptyList()
            guard let store = await poll({ OrdersFixtures.activeListStore }) else { return }
            await settle(store)
        }

        /// Registers a route that never finishes loading, so the screen's own `isLoading` stays
        /// true for as long as the sweep looks at it -- there is nothing to settle here on
        /// purpose.
        @MainActor
        private static func showLoadingList() async {
            OrdersFixtures.registerLoadingList()
            guard let store = await poll({ OrdersFixtures.activeListStore }) else { return }
            Task { await store.load() }
            _ = await poll { store.isLoading ? true : nil }
        }

        @MainActor
        private static func loadDetail() async {
            OrdersFixtures.registerDetail()
            guard let store = await poll({ OrdersFixtures.activeDetailStore }) else { return }
            await settle(store)
        }

        @MainActor
        private static func settle(_ store: OrderListStore) async {
            await store.load()
            if store.errorMessage != nil { await store.load() }
        }

        @MainActor
        private static func settle(_ store: OrderDetailStore) async {
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
