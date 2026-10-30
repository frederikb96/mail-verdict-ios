import Foundation
import MailVerdictKit

#if DEBUG

    /// Orders & tickets' own screenshot entries: the full list, the ticket timeline (online and from
    /// its saved copy), the list's empty and loading states, and details -- a package with its
    /// tracking link, a ticket with its codes, a ticket with files, the code fullscreen, and a ticket
    /// opened with the server unreachable.
    ///
    /// The fixture routes are registered on arrival (`prepare`), not when this array is built --
    /// see `MailboxesScreenshots`'s own note on why.
    enum OrdersScreenshots {
        static let entries: [MVScreenshotEntry] = [
            MVScreenshotEntry(
                id: "orders-list", destination: .route(.orders),
                prepare: { _, _ in
                    OrdersFixtures.registerList()
                    await showList(OrderViewState())
                }),
            MVScreenshotEntry(
                id: "orders-tickets", destination: .route(.orders),
                prepare: { _, _ in
                    OrdersFixtures.registerTicketList()
                    await showList(OrderViewState(kind: .tickets))
                    // The timeline holds today in the middle while its rows settle; the sweep
                    // photographs the held position.
                    try? await Task.sleep(for: .milliseconds(1200))
                }),
            MVScreenshotEntry(
                id: "orders-tickets-offline", destination: .route(.orders),
                prepare: { _, connection in
                    if let cache = connection.offlineCache { await OrdersFixtures.seedOfflineTickets(in: cache) }
                    OrdersFixtures.registerUnreachable()
                    await showList(OrderViewState(kind: .tickets))
                    try? await Task.sleep(for: .milliseconds(1200))
                }),
            MVScreenshotEntry(
                id: "orders-list-empty", destination: .route(.orders),
                prepare: { _, _ in
                    OrdersFixtures.registerEmptyList()
                    await showList(OrderViewState())
                }),
            MVScreenshotEntry(
                id: "orders-list-loading", destination: .route(.orders), prepare: { _, _ in await showLoadingList() }),
            MVScreenshotEntry(
                id: "order-detail", destination: .route(.order(OrdersFixtures.packageOrderId)),
                prepare: { _, _ in await loadDetail() }),
            MVScreenshotEntry(
                id: "order-ticket", destination: .route(.order(OrdersFixtures.ticketOrderId)),
                prepare: { _, _ in await loadDetail() }),
            MVScreenshotEntry(
                id: "order-ticket-files", destination: .route(.order(OrdersFixtures.parkOrderId)),
                prepare: { _, _ in await loadDetailAddingAFile() }),
            MVScreenshotEntry(
                id: "order-code", destination: .route(.order(OrdersFixtures.ticketOrderId)),
                prepare: { _, _ in await loadDetailShowingCode() }),
            MVScreenshotEntry(
                id: "order-ticket-offline", destination: .route(.order(OrdersFixtures.ticketOrderId)),
                prepare: { _, connection in
                    if let cache = connection.offlineCache { await OrdersFixtures.seedOfflineTicket(in: cache) }
                    OrdersFixtures.registerUnreachable(order: OrdersFixtures.ticketOrderId)
                    MailboxesFixtures.registerIfNeeded()
                    guard let store = await poll({ OrdersFixtures.activeDetailStore }) else { return }
                    await settle(store)
                }),
        ]

        @MainActor
        private static func showList(_ view: OrderViewState) async {
            guard let store = await poll({ OrdersFixtures.activeListStore }) else { return }
            await store.setView(view)
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

        /// A file just sent and still being read: the Documents section's "Analysing…" row.
        @MainActor
        private static func loadDetailAddingAFile() async {
            OrdersFixtures.registerDetail()
            OrdersFixtures.registerPendingUpload()
            guard let store = await poll({ OrdersFixtures.activeDetailStore }) else { return }
            await settle(store)
            Task {
                await store.addFile(data: Data([0x89, 0x50]), filename: "boarding-pass.png", contentType: "image/png")
            }
            _ = await poll { store.uploads.first?.state == .analysing ? true : nil }
        }

        /// The first code of the ticket, fullscreen, once its image has drawn.
        @MainActor
        private static func loadDetailShowingCode() async {
            OrdersFixtures.registerDetail()
            guard let store = await poll({ OrdersFixtures.activeDetailStore }) else { return }
            await settle(store)
            guard let fact = store.order?.codeFacts.first else { return }
            store.presentCode(fact)
            _ = await poll { OrdersDebugState.shared.codeShown ? true : nil }
            try? await Task.sleep(for: .milliseconds(600))
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
