import Foundation
import MailVerdictKit

#if DEBUG

    /// Fixture data for the orders list and detail screenshots -- a shipped package order and a
    /// festival ticket for the list, and the package order expanded with its mails (one gone) and
    /// a document for the detail.
    enum OrdersFixtures {
        /// Set from each screen's own `.task` -- `MVScreenshotEntry.prepare` has no reach into a
        /// screen's `@State`, so this is how it finds the instance to reload once fixture routes
        /// exist. Weak: a screen that goes away must not keep its store alive.
        @MainActor static weak var activeListStore: OrderListStore?
        @MainActor static weak var activeDetailStore: OrderDetailStore?

        static let packageOrderId = UUID(uuidString: "00000000-0000-0000-0000-0000000d0001")!
        static let ticketOrderId = UUID(uuidString: "00000000-0000-0000-0000-0000000d0002")!

        private static let openMailKey = UUID(uuidString: "00000000-0000-0000-0000-0000000d0201")!
        private static let openMessageId = UUID(uuidString: "00000000-0000-0000-0000-0000000d0301")!
        private static let goneMailKey = UUID(uuidString: "00000000-0000-0000-0000-0000000d0202")!
        private static let documentAttachmentId = UUID(uuidString: "00000000-0000-0000-0000-0000000d0401")!

        static func registerList() {
            guard MVFixtureLaunch.isEnabled() else { return }
            MailboxesFixtures.registerIfNeeded()
            encodeAndRegister(path: "/api/orders", value: listResponse)
        }

        static func registerEmptyList() {
            guard MVFixtureLaunch.isEnabled() else { return }
            MailboxesFixtures.registerIfNeeded()
            encodeAndRegister(
                path: "/api/orders", value: OrderListResponse(items: [], hasMore: false, nextCursor: nil))
        }

        static func registerLoadingList() {
            guard MVFixtureLaunch.isEnabled() else { return }
            MailboxesFixtures.registerIfNeeded()
            MVFixtureURLProtocol.register(method: "GET", path: "/api/orders", keepOpen: true) { Data() }
        }

        static func registerDetail() {
            guard MVFixtureLaunch.isEnabled() else { return }
            MailboxesFixtures.registerIfNeeded()
            encodeAndRegister(path: "/api/orders/\(packageOrderId.uuidString)", value: detailResponse)
        }

        /// Encoded eagerly, outside the closure: these response types are not `Sendable`, and the
        /// fixture body closure is `@Sendable` -- caught only on a Mac compile.
        private static func encodeAndRegister<T: Encodable>(path: String, value: T) {
            let data = (try? JSONEncoder.mvDefault.encode(value)) ?? Data("{}".utf8)
            MVFixtureURLProtocol.register(method: "GET", path: path) { data }
        }

        private static var listResponse: OrderListResponse {
            OrderListResponse(
                items: [
                    OrderListItem(
                        id: packageOrderId, merchant: "Nordlicht Keramik", subject: "Handcrafted blue glazed vase",
                        status: "shipped", title: "Handcrafted blue glazed vase — shipped", isOpen: true,
                        icon: "package", summaryPreview: "Ordered and shipped, tracking NK-48213, on its way.",
                        firstMailAt: Date(timeIntervalSinceNow: -86400 * 4),
                        lastMailAt: Date(timeIntervalSinceNow: -86400 * 2), mailCount: 3,
                        accountIds: [MailboxesFixtures.accountId],
                        textStale: false, updatedAt: Date(timeIntervalSinceNow: -86400 * 2), isFavorite: true
                    ),
                    OrderListItem(
                        id: ticketOrderId, merchant: "Hafenklang Festival", subject: "Weekend pass",
                        status: "confirmed", title: "Weekend pass — confirmed", isOpen: false, icon: "ticket",
                        summaryPreview: "One weekend pass, ticket HKF-77210, entry from 09:00.",
                        firstMailAt: Date(timeIntervalSinceNow: -86400 * 30),
                        lastMailAt: Date(timeIntervalSinceNow: -86400 * 30), mailCount: 1,
                        accountIds: [MailboxesFixtures.accountId],
                        textStale: false, updatedAt: Date(timeIntervalSinceNow: -86400 * 30), isSealed: true,
                        openSetBy: "auto"
                    ),
                ],
                hasMore: false, nextCursor: nil
            )
        }

        private static var detailResponse: OrderDetail {
            OrderDetail(
                id: packageOrderId, merchant: "Nordlicht Keramik", subject: "Handcrafted blue glazed vase",
                status: "shipped", title: "Handcrafted blue glazed vase — shipped", isOpen: true, icon: "package",
                summaryPreview: "Ordered and shipped, tracking NK-48213, on its way.",
                firstMailAt: Date(timeIntervalSinceNow: -86400 * 4), lastMailAt: Date(timeIntervalSinceNow: -86400 * 2),
                mailCount: 3, accountIds: [MailboxesFixtures.accountId], textStale: false,
                updatedAt: Date(timeIntervalSinceNow: -86400 * 2),
                summary: "Ordered a **Handcrafted blue glazed vase** for EUR 49.90.\n\n"
                    + "- Order number NK-48213\n- Shipped with tracking\n- Delivery expected within 3 days",
                identifiers: [
                    OrderIdentifierOut(kind: "order_number", value: "NK-48213"),
                    OrderIdentifierOut(kind: "tracking_number", value: "NK-TRACK-99201"),
                ],
                mails: [
                    OrderMailOut(
                        key: openMailKey, accountId: MailboxesFixtures.accountId, messageId: openMessageId,
                        threadId: nil, location: "mailbox", folderId: MailboxesFixtures.inboxId, isSeen: true,
                        subject: "Your order is confirmed", fromAddr: "shop@nordlicht-keramik.example",
                        receivedAt: Date(timeIntervalSinceNow: -86400 * 4), attachedBy: "ai"
                    ),
                    OrderMailOut(
                        key: goneMailKey, accountId: MailboxesFixtures.accountId, messageId: nil, threadId: nil,
                        location: "gone", folderId: nil, isSeen: nil, subject: "Payment received",
                        fromAddr: "billing@nordlicht-keramik.example",
                        receivedAt: Date(timeIntervalSinceNow: -86400 * 3),
                        attachedBy: "ai"
                    ),
                ],
                documents: [
                    OrderDocumentOut(
                        messageId: openMessageId, attachmentId: documentAttachmentId, filename: "invoice-NK-48213.pdf",
                        contentType: "application/pdf", sizeBytes: 84_213,
                        receivedAt: Date(timeIntervalSinceNow: -86400 * 4)
                    )
                ]
            )
        }
    }

#endif
