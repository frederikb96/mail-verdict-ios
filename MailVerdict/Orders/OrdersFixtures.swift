import CoreImage
import CoreImage.CIFilterBuiltins
import Foundation
import MailVerdictKit
import UIKit

#if DEBUG

    /// Fixture data for the orders screenshots: a ticket timeline reaching a few weeks either side
    /// of today (dates are relative to the launch, so "today" is always in the middle), a shipped
    /// package and a subscription for the full list, and details with key facts, codes and files.
    enum OrdersFixtures {
        /// Set from each screen's own `.task` -- `MVScreenshotEntry.prepare` has no reach into a
        /// screen's `@State`, so this is how it finds the instance to reload once fixture routes
        /// exist. Weak: a screen that goes away must not keep its store alive.
        @MainActor static weak var activeListStore: OrderListStore?
        @MainActor static weak var activeDetailStore: OrderDetailStore?

        static let packageOrderId = id(0x0001)
        /// The Deutsche Bahn ticket two days ahead: two codes, the richest detail.
        static let ticketOrderId = id(0x0002)
        /// The theme-park ticket: one code and added files.
        static let parkOrderId = id(0x1001)
        static let subscriptionOrderId = id(0x0004)

        static let aztecFactId = id(0x2001)
        static let qrFactId = id(0x2002)
        static let parkCodeFactId = id(0x2003)

        private static let openMailKey = id(0x0201)
        private static let openMessageId = id(0x0301)
        private static let goneMailKey = id(0x0202)
        private static let documentAttachmentId = id(0x0401)

        private static func id(_ n: Int) -> UUID {
            UUID(uuidString: String(format: "00000000-0000-0000-0000-0000000d%04x", n))!
        }

        // MARK: Tickets

        private struct Seed {
            let id: UUID
            let merchant: String
            let subject: String
            let status: String
            let icon: String
            /// Whole days from today; the event's start.
            let offset: Int
            var lasts = 0
            var isOpen = true
            var isFavorite = false
        }

        private static let ticketSeeds: [Seed] = [
            Seed(
                id: parkOrderId, merchant: "Phantasialand", subject: "Day ticket", status: "ticket issued",
                icon: "ticket", offset: 21),
            Seed(
                id: id(0x1002), merchant: "FlixBus", subject: "Aachen to Paris", status: "booked", icon: "bus",
                offset: 16),
            Seed(
                id: id(0x1003), merchant: "Eurostar", subject: "Brussels to London", status: "ticket issued",
                icon: "train", offset: 12, isFavorite: true),
            Seed(
                id: id(0x1004), merchant: "Cinestar", subject: "Evening show, row F", status: "confirmed",
                icon: "ticket", offset: 9),
            Seed(
                id: id(0x1005), merchant: "Hotel Ibis", subject: "Two nights in Cologne", status: "booked", icon: "bed",
                offset: 6, lasts: 2),
            Seed(
                id: id(0x1006), merchant: "NS", subject: "Heerlen to Amsterdam Centraal", status: "ticket issued",
                icon: "train", offset: 4),
            Seed(
                id: ticketOrderId, merchant: "Deutsche Bahn", subject: "Aachen to Berlin", status: "ticket issued",
                icon: "train", offset: 2, isFavorite: true),
            Seed(
                id: id(0x1007), merchant: "Boulderhalle Aachen", subject: "Ten-visit card", status: "confirmed",
                icon: "ticket", offset: 1),
            Seed(
                id: id(0x1008), merchant: "Open-Air Kino", subject: "Film night", status: "confirmed", icon: "ticket",
                offset: 0),
            Seed(
                id: id(0x1009), merchant: "NS", subject: "Amsterdam Centraal to Heerlen", status: "used", icon: "train",
                offset: -3, isOpen: false),
            Seed(
                id: id(0x100a), merchant: "Deutsche Bahn", subject: "Cologne to Aachen", status: "used", icon: "train",
                offset: -9, isOpen: false),
            Seed(
                id: id(0x100b), merchant: "Lufthansa", subject: "Brussels to Munich", status: "flown", icon: "plane",
                offset: -14, isOpen: false),
            Seed(
                id: id(0x100c), merchant: "Booking.com", subject: "Four nights in Lisbon", status: "stayed",
                icon: "bed", offset: -26, lasts: 4, isOpen: false),
            Seed(
                id: id(0x100d), merchant: "Hafenklang Festival", subject: "Weekend pass", status: "confirmed",
                icon: "ticket", offset: -35, lasts: 2, isOpen: false),
            Seed(
                id: id(0x100e), merchant: "FlixBus", subject: "Paris to Aachen", status: "used", icon: "bus",
                offset: -50, isOpen: false),
            Seed(
                id: id(0x100f), merchant: "Stadttheater", subject: "Faust, stalls", status: "attended", icon: "ticket",
                offset: -64, isOpen: false),
            Seed(
                id: id(0x1010), merchant: "Deutsche Bahn", subject: "Aachen to Hamburg", status: "used", icon: "train",
                offset: -80, isOpen: false),
            Seed(
                id: id(0x1011), merchant: "Zoo Antwerpen", subject: "Family day ticket", status: "attended",
                icon: "ticket", offset: -95, isOpen: false),
        ]

        private static func day(_ offset: Int) -> String {
            let date = Calendar.current.date(byAdding: .day, value: offset, to: Date()) ?? Date()
            return MVOrderDay.string(for: date)
        }

        private static func at(_ offset: Int, hour: Int = 9) -> Date {
            let base = Calendar.current.date(byAdding: .day, value: offset, to: Date()) ?? Date()
            return Calendar.current.date(bySettingHour: hour, minute: 0, second: 0, of: base) ?? base
        }

        private static func listItem(_ seed: Seed) -> OrderListItem {
            let start = day(seed.offset)
            let activity = at(min(seed.offset, 0) - 7)
            return OrderListItem(
                id: seed.id, merchant: seed.merchant, subject: seed.subject, status: seed.status,
                title: "\(seed.subject) — \(seed.status)", isOpen: seed.isOpen, icon: seed.icon,
                summaryPreview: "\(seed.subject), \(seed.status).", firstMailAt: activity, lastMailAt: activity,
                mailCount: 1, accountIds: [MailboxesFixtures.accountId], textStale: false, updatedAt: activity,
                isFavorite: seed.isFavorite, kind: .ticket, eventStart: start,
                eventEnd: seed.lasts > 0 ? day(seed.offset + seed.lasts) : nil, timelineDate: start,
                firstActivityAt: activity, lastActivityAt: activity)
        }

        private static var packageListItem: OrderListItem {
            OrderListItem(
                id: packageOrderId, merchant: "Nordlicht Keramik", subject: "Handcrafted blue glazed vase",
                status: "shipped", title: "Handcrafted blue glazed vase — shipped", isOpen: true, icon: "package",
                summaryPreview: "Ordered and shipped, tracking NK-48213, on its way.", firstMailAt: at(-4),
                lastMailAt: at(-2), mailCount: 3, accountIds: [MailboxesFixtures.accountId], textStale: false,
                updatedAt: at(-2), isFavorite: true, kind: .order, timelineDate: day(-4), firstActivityAt: at(-4),
                lastActivityAt: at(-2))
        }

        private static var subscriptionListItem: OrderListItem {
            OrderListItem(
                id: subscriptionOrderId, merchant: "Audiobook Club", subject: "Monthly membership",
                status: "renewed", title: "Monthly membership — renewed", isOpen: true, icon: "download",
                summaryPreview: "Renews on the 3rd of each month, EUR 9.95.", firstMailAt: at(-40),
                lastMailAt: at(-8), mailCount: 6, accountIds: [MailboxesFixtures.accountId], textStale: false,
                updatedAt: at(-8), kind: .other, timelineDate: day(-40), firstActivityAt: at(-40),
                lastActivityAt: at(-8))
        }

        // MARK: Registration

        /// Everything the screens ask for, with the full list showing mixed kinds.
        static func registerList() {
            guard MVFixtureLaunch.isEnabled() else { return }
            MailboxesFixtures.registerIfNeeded()
            registerDetails()
            let items =
                [packageListItem, listItem(ticketSeeds[6]), subscriptionListItem]
                + ticketSeeds.filter { $0.id != ticketOrderId }.prefix(6).map(listItem)
            encodeAndRegister(
                path: "/api/orders", value: OrderListResponse(items: items, hasMore: false, nextCursor: nil))
        }

        /// The ticket timeline: only tickets, as the server's `kind=ticket&sort=event` answers.
        static func registerTicketList() {
            guard MVFixtureLaunch.isEnabled() else { return }
            MailboxesFixtures.registerIfNeeded()
            registerDetails()
            encodeAndRegister(
                path: "/api/orders",
                value: OrderListResponse(items: ticketSeeds.reversed().map(listItem), hasMore: false, nextCursor: nil))
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

        /// A server that cannot be reached, as a gateway reports it: what the saved copy stands in for.
        static func registerUnreachable(order orderId: UUID? = nil) {
            guard MVFixtureLaunch.isEnabled() else { return }
            let body: @Sendable () -> Data = { Data(#"{"detail":"Service unavailable"}"#.utf8) }
            MVFixtureURLProtocol.register(method: "GET", path: "/api/orders", status: 503, body: body)
            if let orderId {
                MVFixtureURLProtocol.register(method: "GET", path: "/api/orders/\(orderId)", status: 503, body: body)
                for fact in [aztecFactId, qrFactId] {
                    MVFixtureURLProtocol.register(
                        method: "GET", path: "/api/orders/\(orderId)/codes/\(fact).png", status: 503, body: body)
                }
            }
        }

        static func registerDetail() {
            guard MVFixtureLaunch.isEnabled() else { return }
            MailboxesFixtures.registerIfNeeded()
            registerDetails()
        }

        /// A file the server accepted and has not placed yet: the add-file flow's "analysing" state.
        static func registerPendingUpload() {
            guard MVFixtureLaunch.isEnabled() else { return }
            let fileId = id(0x3001)
            let status = OrderFileStatus(fileId: fileId, orderId: nil, status: "pending")
            let data = (try? JSONEncoder.mvDefault.encode(status)) ?? Data("{}".utf8)
            MVFixtureURLProtocol.register(method: "POST", path: "/api/orders/files", status: 202) { data }
            MVFixtureURLProtocol.register(method: "GET", path: "/api/orders/files/\(fileId)") { data }
        }

        /// Encoded eagerly, outside the closure: these response types are not `Sendable`, and the
        /// fixture body closure is `@Sendable` -- caught only on a Mac compile.
        private static func encodeAndRegister<T: Encodable>(path: String, value: T) {
            let data = (try? JSONEncoder.mvDefault.encode(value)) ?? Data("{}".utf8)
            MVFixtureURLProtocol.register(method: "GET", path: path) { data }
        }

        /// Every detail the list can lead to: opening a ticket, and the ahead-of-time copy of the
        /// upcoming ones, both ask for these.
        private static func registerDetails() {
            encodeAndRegister(path: "/api/orders/\(packageOrderId)", value: packageDetail)
            encodeAndRegister(path: "/api/orders/\(subscriptionOrderId)", value: subscriptionDetail)
            for seed in ticketSeeds {
                encodeAndRegister(path: "/api/orders/\(seed.id)", value: ticketDetail(seed))
            }
            for (fact, payload, aztec) in [
                (aztecFactId, "DB-TICKET-5471205382-AACHEN-BERLIN", true),
                (qrFactId, "5471205382", false),
                (parkCodeFactId, "PHANTASIA-DAYTICKET-88213", false),
            ] {
                let png = codePNG(payload: payload, aztec: aztec)
                for seed in ticketSeeds {
                    MVFixtureURLProtocol.register(method: "GET", path: "/api/orders/\(seed.id)/codes/\(fact).png") {
                        png
                    }
                }
            }
        }

        /// A code drawn the way the server draws one: the quiet zone included, sharp edges.
        static func codePNG(payload: String, aztec: Bool) -> Data {
            let message = Data(payload.utf8)
            let output: CIImage?
            if aztec {
                let filter = CIFilter.aztecCodeGenerator()
                filter.message = message
                output = filter.outputImage
            } else {
                let filter = CIFilter.qrCodeGenerator()
                filter.message = message
                output = filter.outputImage
            }
            guard let output else { return Data() }
            let scaled = output.transformed(by: CGAffineTransform(scaleX: 8, y: 8))
            let padded = scaled.composited(
                over: CIImage(color: .white).cropped(to: scaled.extent.insetBy(dx: -64, dy: -64)))
            let context = CIContext()
            guard let cg = context.createCGImage(padded, from: padded.extent) else { return Data() }
            return UIImage(cgImage: cg).pngData() ?? Data()
        }

        // MARK: Offline copy

        /// What an earlier online visit leaves on the device for the Deutsche Bahn ticket: its
        /// detail and both code images.
        static func seedOfflineTicket(in cache: MVOfflineCache) async {
            guard let hero = ticketSeeds.first(where: { $0.id == ticketOrderId }) else { return }
            await cache.saveOrder(ticketDetail(hero))
            await cache.saveOrderCode(
                codePNG(payload: "DB-TICKET-5471205382-AACHEN-BERLIN", aztec: true), factId: aztecFactId)
            await cache.saveOrderCode(codePNG(payload: "5471205382", aztec: false), factId: qrFactId)
        }

        /// The ticket timeline an earlier online visit saved.
        static func seedOfflineTickets(in cache: MVOfflineCache) async {
            await cache.saveOrderList(
                ticketSeeds.reversed().map(listItem), hasMore: false,
                key: OrderViewState(kind: .tickets).identity)
        }

        // MARK: Details

        private static func fact(
            _ id: UUID, _ kind: OrderFactKind, _ label: String, _ value: String, carrier: String? = nil,
            trackingUrl: String? = nil, code: OrderCodeOut? = nil
        ) -> OrderFactOut {
            OrderFactOut(
                id: id, kind: kind, label: label, value: value, carrier: carrier, trackingUrl: trackingUrl, code: code)
        }

        private static func codeOut(order: UUID, fact: UUID, format: String, payload: String?) -> OrderCodeOut {
            OrderCodeOut(
                format: format, payloadText: payload, imageUrl: "/api/orders/\(order)/codes/\(fact).png", page: 1)
        }

        private static func ticketDetail(_ seed: Seed) -> OrderDetail {
            let start = day(seed.offset)
            var facts: [OrderFactOut] = []
            var documents: [OrderDocumentOut] = []
            var summary = "\(seed.subject) with \(seed.merchant).\n\n- Booking confirmed by mail"
            if seed.id == ticketOrderId {
                summary = "Train ticket from **Aachen Hbf** to **Berlin Hbf**, flexible fare, one passenger."
                facts = [
                    fact(
                        aztecFactId, .code, "Ticketcode", "",
                        code: codeOut(order: seed.id, fact: aztecFactId, format: "Aztec", payload: nil)),
                    fact(
                        qrFactId, .code, "Booking QR", "5471205382",
                        code: codeOut(order: seed.id, fact: qrFactId, format: "QR", payload: "5471205382")),
                    fact(id(0x2101), .bookingCode, "Booking code", "E551807712"),
                    fact(id(0x2102), .time, "Departure", "08:21"),
                    fact(id(0x2103), .place, "From", "Aachen Hbf, platform 4"),
                    fact(id(0x2104), .seat, "Seat", "Coach 22, seat 61"),
                    fact(id(0x2105), .person, "Passenger", "Alex Example"),
                ]
                documents = [
                    OrderDocumentOut(
                        id: id(0x4001), source: "mail", messageId: openMessageId, attachmentId: documentAttachmentId,
                        fileId: nil, filename: "Online-Ticket.pdf", contentType: "application/pdf", sizeBytes: 211_000,
                        receivedAt: at(-3), pageCount: 2, method: "text_layer", barcodeCount: 2,
                        downloadUrl: "/api/messages/\(openMessageId)/attachments/\(documentAttachmentId)")
                ]
            } else if seed.id == parkOrderId {
                facts = [
                    fact(
                        parkCodeFactId, .code, "Entry code", "",
                        code: codeOut(
                            order: seed.id, fact: parkCodeFactId, format: "QR", payload: "PHANTASIA-DAYTICKET-88213")),
                    fact(id(0x2111), .bookingCode, "Order", "PL-3321908"),
                ]
                documents = [
                    OrderDocumentOut(
                        id: id(0x4201), source: "mail", messageId: openMessageId, attachmentId: documentAttachmentId,
                        fileId: nil, filename: "Phantasialand-ticket.pdf", contentType: "application/pdf",
                        sizeBytes: 148_000, receivedAt: at(-6), pageCount: 1, method: "text_layer", barcodeCount: 1,
                        downloadUrl: "/api/messages/\(openMessageId)/attachments/\(documentAttachmentId)"),
                    OrderDocumentOut(
                        id: id(0x4202), source: "file", messageId: nil, attachmentId: nil, fileId: id(0x3002),
                        filename: "parking-reservation.png", contentType: "image/png", sizeBytes: 392_000,
                        receivedAt: at(-1), pageCount: 1, method: "ocr", barcodeCount: 0,
                        downloadUrl: "/api/orders/\(seed.id)/files/\(id(0x3002))"),
                ]
            } else {
                facts = [fact(id(0x2121), .bookingCode, "Booking code", "BK-\(seed.offset + 1000)")]
            }
            return OrderDetail(
                id: seed.id, merchant: seed.merchant, subject: seed.subject, status: seed.status,
                title: "\(seed.subject) — \(seed.status)", isOpen: seed.isOpen, icon: seed.icon,
                summaryPreview: summary, firstMailAt: at(-3), lastMailAt: at(-3), mailCount: 1,
                accountIds: [MailboxesFixtures.accountId], textStale: false, updatedAt: at(min(seed.offset, 0) - 7),
                summary: summary, facts: facts, mails: [], documents: documents, isFavorite: seed.isFavorite,
                kind: .ticket, eventStart: start, eventEnd: seed.lasts > 0 ? day(seed.offset + seed.lasts) : nil,
                timelineDate: start, firstActivityAt: at(-3), lastActivityAt: at(-3),
                fileCount: documents.filter(\.isFile).count)
        }

        private static var subscriptionDetail: OrderDetail {
            OrderDetail(
                id: subscriptionOrderId, merchant: "Audiobook Club", subject: "Monthly membership",
                status: "renewed", title: "Monthly membership — renewed", isOpen: true, icon: "download",
                summaryPreview: "Renews on the 3rd.", firstMailAt: at(-40), lastMailAt: at(-8), mailCount: 6,
                accountIds: [MailboxesFixtures.accountId], textStale: false, updatedAt: at(-8),
                summary: "Membership renewed every month, **EUR 9.95**.", facts: [], mails: [], documents: [],
                kind: .other, timelineDate: day(-40), firstActivityAt: at(-40), lastActivityAt: at(-8))
        }

        private static var packageDetail: OrderDetail {
            OrderDetail(
                id: packageOrderId, merchant: "Nordlicht Keramik", subject: "Handcrafted blue glazed vase",
                status: "shipped", title: "Handcrafted blue glazed vase — shipped", isOpen: true, icon: "package",
                summaryPreview: "Ordered and shipped, tracking NK-48213, on its way.", firstMailAt: at(-4),
                lastMailAt: at(-2), mailCount: 3, accountIds: [MailboxesFixtures.accountId], textStale: false,
                updatedAt: at(-2),
                summary: "Ordered a **Handcrafted blue glazed vase** for EUR 49.90.\n\n"
                    + "- Order number NK-48213\n- Shipped with tracking\n- Delivery expected within 3 days",
                facts: [
                    fact(id(0x2201), .orderNumber, "Order number", "NK-48213"),
                    fact(
                        id(0x2202), .trackingNumber, "Tracking", "00340434161094042557", carrier: "dhl",
                        trackingUrl:
                            "https://www.dhl.de/de/privatkunden/pakete-empfangen/verfolgen.html?piececode=00340434161094042557"
                    ),
                    fact(id(0x2203), .amount, "Total", "EUR 49.90"),
                    fact(id(0x2204), .place, "Delivery", "Packstation 142, Aachen"),
                ],
                mails: [
                    OrderMailOut(
                        key: openMailKey, accountId: MailboxesFixtures.accountId, messageId: openMessageId,
                        threadId: nil, location: "mailbox", folderId: MailboxesFixtures.inboxId, isSeen: true,
                        subject: "Your order is confirmed", fromAddr: "shop@nordlicht-keramik.example",
                        receivedAt: at(-4), attachedBy: "ai"
                    ),
                    OrderMailOut(
                        key: goneMailKey, accountId: MailboxesFixtures.accountId, messageId: nil, threadId: nil,
                        location: "gone", folderId: nil, isSeen: nil, subject: "Payment received",
                        fromAddr: "billing@nordlicht-keramik.example", receivedAt: at(-3), attachedBy: "ai"
                    ),
                ],
                documents: [
                    OrderDocumentOut(
                        id: id(0x4101), source: "mail", messageId: openMessageId, attachmentId: documentAttachmentId,
                        fileId: nil, filename: "invoice-NK-48213.pdf", contentType: "application/pdf",
                        sizeBytes: 84_213, receivedAt: at(-4), pageCount: 1, method: "text_layer", barcodeCount: 0,
                        downloadUrl: "/api/messages/\(openMessageId)/attachments/\(documentAttachmentId)")
                ],
                isFavorite: true, kind: .order, timelineDate: day(-4), firstActivityAt: at(-4), lastActivityAt: at(-2))
        }
    }

#endif
