#if DEBUG

    import Foundation

    /// The reader's fixture corpus — a small list whose conversations cover every page shape the
    /// reader draws: a reply with a collapsed quote and attachments, a fixed-width newsletter
    /// with blocked images, an invitation already in a calendar (RSVP row) and one awaiting
    /// review, and a plain-text message. `install()` answers every endpoint the reader calls, so
    /// a fixture-mode run and the screenshot sweep need no backend.
    public enum ReaderFixtures {

        public static let accountId = UUID(uuidString: "5B1D7E0A-3C2F-4B8E-9F10-2A6C4D8E0001")!
        public static let inboxId = UUID(uuidString: "5B1D7E0A-3C2F-4B8E-9F10-2A6C4D8E0002")!
        public static let trashId = UUID(uuidString: "5B1D7E0A-3C2F-4B8E-9F10-2A6C4D8E0003")!

        public static let conversationRowId = UUID(uuidString: "5B1D7E0A-3C2F-4B8E-9F10-2A6C4D8E0101")!
        static let conversationEarlierId = UUID(uuidString: "5B1D7E0A-3C2F-4B8E-9F10-2A6C4D8E0102")!
        public static let newsletterRowId = UUID(uuidString: "5B1D7E0A-3C2F-4B8E-9F10-2A6C4D8E0103")!
        public static let invitationRowId = UUID(uuidString: "5B1D7E0A-3C2F-4B8E-9F10-2A6C4D8E0104")!
        public static let reviewRowId = UUID(uuidString: "5B1D7E0A-3C2F-4B8E-9F10-2A6C4D8E0105")!
        public static let plainRowId = UUID(uuidString: "5B1D7E0A-3C2F-4B8E-9F10-2A6C4D8E0106")!

        static let pdfAttachmentId = UUID(uuidString: "5B1D7E0A-3C2F-4B8E-9F10-2A6C4D8E0201")!
        static let imageAttachmentId = UUID(uuidString: "5B1D7E0A-3C2F-4B8E-9F10-2A6C4D8E0202")!
        static let inviteAttachmentId = UUID(uuidString: "5B1D7E0A-3C2F-4B8E-9F10-2A6C4D8E0203")!
        static let reviewAttachmentId = UUID(uuidString: "5B1D7E0A-3C2F-4B8E-9F10-2A6C4D8E0204")!
        static let calendarId = UUID(uuidString: "5B1D7E0A-3C2F-4B8E-9F10-2A6C4D8E0301")!
        static let identityId = UUID(uuidString: "5B1D7E0A-3C2F-4B8E-9F10-2A6C4D8E0302")!
        static let eventObjectId = UUID(uuidString: "5B1D7E0A-3C2F-4B8E-9F10-2A6C4D8E0303")!
        static let reviewObjectId = UUID(uuidString: "5B1D7E0A-3C2F-4B8E-9F10-2A6C4D8E0304")!

        /// List order, newest first.
        public static let rowIds = [conversationRowId, invitationRowId, newsletterRowId, reviewRowId, plainRowId]

        public static let listSource = ReaderContext.Source.list(.folder(accountId: accountId, folderId: inboxId))

        public static func context(opening rowId: UUID) -> ReaderContext {
            ReaderContext(source: listSource, messageId: rowId)
        }

        /// The list the fixture reader pages through.
        @MainActor
        public final class Source: ReaderListSource {
            public let rowIds = ReaderFixtures.rowIds
            public let hasOlder = false
            public let hasNewer = false
            public var readerTitle: String? { "\(rowIds.count) Messages" }

            public func loadOlder() async {}
            public func loadNewer() async {}
        }

        @MainActor public static let source = Source()

        /// Registers every fixture route and the fixture list with the reader. Safe to call again.
        @MainActor
        public static func install() {
            ReaderSourceRegistry.shared.register(source, for: listSource)
            for (rowId, thread) in threads() {
                MVFixtureURLProtocol.register(method: "GET", path: "/api/messages/\(rowId)/thread") { json(thread) }
                for message in thread.messages {
                    MVFixtureURLProtocol.register(method: "GET", path: "/api/messages/\(message.id)") { json(message) }
                    MVFixtureURLProtocol.register(method: "POST", path: "/api/messages/\(message.id)/action") {
                        json(MessageActionResponse(success: true, action: "ok", messageId: message.id, message: nil))
                    }
                }
            }
            MVFixtureURLProtocol.register(method: "GET", path: "/api/accounts/\(accountId)/folders") { json(folders) }
            MVFixtureURLProtocol.register(method: "GET", path: "/api/contacts/photo-index") {
                json(ContactPhotoIndexResponse(byEmail: [:]))
            }
            MVFixtureURLProtocol.register(method: "GET", path: "/api/alerts") { json([AlertResponse]()) }
            MVFixtureURLProtocol.register(method: "GET", path: "/api/calendars") { json([calendar]) }
            MVFixtureURLProtocol.register(method: "GET", path: "/api/identities") { json([identity]) }
            MVFixtureURLProtocol.register(method: "GET", path: "/api/calendar/invitations/\(invitationRowId)") {
                json(importedInvitation)
            }
            MVFixtureURLProtocol.register(method: "GET", path: "/api/calendar/invitations/\(reviewRowId)") {
                json(reviewInvitation)
            }
            MVFixtureURLProtocol.register(method: "GET", path: "/api/calendar/events/\(eventObjectId)") { json(event) }
            MVFixtureURLProtocol.register(
                method: "GET", path: "/api/messages/\(conversationRowId)/attachments/\(pdfAttachmentId)"
            ) { Data(minimalPDF.utf8) }
        }

        // MARK: Data

        static let reference = Date(timeIntervalSince1970: 1_789_000_000)

        public static func threads() -> [UUID: ThreadResponse] {
            [
                conversationRowId: ThreadResponse(messages: [earlierMessage, replyMessage]),
                newsletterRowId: ThreadResponse(messages: [newsletterMessage]),
                invitationRowId: ThreadResponse(messages: [invitationMessage]),
                reviewRowId: ThreadResponse(messages: [reviewMessage]),
                plainRowId: ThreadResponse(messages: [plainMessage]),
            ]
        }

        static func message(
            id: UUID, from: String, to: [String], subject: String, html: String?, text: String?,
            minutesAgo: Double, isSeen: Bool = true, verdict: VerdictResponse? = nil,
            attachments: [AttachmentSummary] = [], hasBlockedImages: Bool = false
        ) -> MessageDetail {
            MessageDetail(
                id: id, accountId: accountId, folderId: inboxId, threadId: id, subject: subject, fromAddr: from,
                toAddrs: .array(to), receivedAt: reference.addingTimeInterval(-minutesAgo * 60), isSeen: isSeen,
                snippet: text.map { String($0.prefix(120)) } ?? "", messageId: "<\(id)@fixture.invalid>",
                ccAddrs: nil, bccAddrs: nil, replyTo: nil, inReplyTo: nil, references: nil, bodyText: text,
                bodyHtml: html, sizeBytes: 4096, hasBlockedImages: hasBlockedImages, imagesAllowed: false,
                createdAt: reference, attachments: attachments, verdict: verdict)
        }

        static let earlierMessage = message(
            id: conversationEarlierId, from: "Alice Martin <alice@example.org>", to: ["me@example.org"],
            subject: "Trip to Lisbon", html: "<p>Hi! Shall we book the flights for the second week of October?</p>",
            text: "Hi! Shall we book the flights for the second week of October?", minutesAgo: 180)

        static let replyMessage = message(
            id: conversationRowId, from: "Bob Keller <bob@example.org>", to: ["alice@example.org", "me@example.org"],
            subject: "Re: Trip to Lisbon",
            html: """
                <p>Yes — the Tuesday flight is cheapest. Itinerary and a photo of the hotel attached.</p>\
                <p>Tickets: <a href="https://example.org/booking">example.org/booking</a></p>\
                <blockquote type="cite"><p>Hi! Shall we book the flights for the second week of October?</p></blockquote>
                """,
            text: "Yes — the Tuesday flight is cheapest.", minutesAgo: 25, isSeen: false,
            verdict: VerdictResponse(
                id: UUID(uuidString: "5B1D7E0A-3C2F-4B8E-9F10-2A6C4D8E0401")!, messageId: conversationRowId,
                isSpam: false, modelUsed: "fixture-model", reasoning: "A reply within an existing conversation.",
                source: "ai", createdAt: reference),
            attachments: [
                AttachmentSummary(
                    id: pdfAttachmentId, filename: "Itinerary.pdf", contentType: "application/pdf", sizeBytes: 182_000),
                AttachmentSummary(
                    id: imageAttachmentId, filename: "hotel.jpg", contentType: "image/jpeg", sizeBytes: 1_240_000),
            ])

        static let newsletterMessage = message(
            id: newsletterRowId, from: "Weekly Digest <news@digest.example>", to: ["me@example.org"],
            subject: "This week: ten things worth reading",
            html: """
                <style>@media (prefers-color-scheme: dark) { .card { background: #1f2937; color: #f9fafb; } }</style>\
                <table width="600" style="width: 600px; background: #f3f4f6"><tr><td class="card" style="padding: 24px">\
                <h1>Ten things worth reading</h1><p>A fixed-width newsletter, fitted to the page at rest zoom.</p>\
                <p><img src="https://digest.example/banner.png" width="552" height="120" alt="Banner"></p>\
                </td></tr></table>
                """,
            text: "Ten things worth reading", minutesAgo: 300, hasBlockedImages: true)

        static let invitationMessage = message(
            id: invitationRowId, from: "Carla Diaz <carla@example.org>", to: ["me@example.org"],
            subject: "Invitation: Project kickoff", html: "<p>Looking forward to kicking this off together.</p>",
            text: "Looking forward to kicking this off together.", minutesAgo: 90,
            attachments: [
                AttachmentSummary(
                    id: inviteAttachmentId, filename: "invite.ics", contentType: "text/calendar", sizeBytes: 2_100)
            ])

        static let reviewMessage = message(
            id: reviewRowId, from: "Organizer <organizer@lookalike.example>", to: ["me@example.org"],
            subject: "Cancelled: Project kickoff", html: "<p>This meeting has been cancelled.</p>",
            text: "This meeting has been cancelled.", minutesAgo: 400,
            attachments: [
                AttachmentSummary(
                    id: reviewAttachmentId, filename: "cancel.ics", contentType: "text/calendar", sizeBytes: 1_800)
            ])

        static let plainMessage = message(
            id: plainRowId, from: "Dana <dana@example.org>", to: ["me@example.org"], subject: "Notes from today",
            html: nil, text: "Here are the notes:\n\n- ship the reader\n- details at https://example.org/notes\n",
            minutesAgo: 1_500)

        static let folders = [
            FolderResponse(
                id: inboxId, accountId: accountId, imapName: "INBOX", displayName: "Inbox", specialUse: "inbox",
                mailboxId: nil, backfillTotal: nil, idleStatus: nil, lastSyncedAt: reference, syncError: nil,
                createdAt: reference, unreadCount: 1, totalCount: rowIds.count),
            FolderResponse(
                id: trashId, accountId: accountId, imapName: "Trash", displayName: "Trash", specialUse: "trash",
                mailboxId: nil, backfillTotal: nil, idleStatus: nil, lastSyncedAt: reference, syncError: nil,
                createdAt: reference),
        ]

        static let calendar = MVCalendar(
            id: calendarId, davAccountId: accountId, davAccountName: "Personal", displayName: "Personal",
            color: "#22c55e", colorOverride: nil, isVisible: true, isEnabled: true, readOnly: false,
            identityId: identityId, intake: .importOnly, holdsEvents: true, syncError: nil, initialSyncDone: true,
            totalCount: 12, defaultReminderMinutes: nil, remindersEnabled: nil, resolvedDefaultReminderMinutes: nil)

        static let identity = IdentityResponse(
            id: identityId, accountId: accountId, address: "me@example.org", displayName: "Me", isDefault: true,
            createdAt: reference)

        static let kickoffStart = reference.addingTimeInterval(3 * 86_400)

        static let attendees = [
            EventAttendee(email: "carla@example.org", cn: "Carla Diaz", partstat: .accepted, role: .chair),
            EventAttendee(email: "me@example.org", cn: "Me", partstat: .needsAction, role: .reqParticipant),
            EventAttendee(email: "bob@example.org", cn: "Bob Keller", partstat: .tentative, role: .reqParticipant),
        ]

        static let importedInvitation = Invitation(
            messageId: invitationRowId, method: .request, status: .imported, uid: "kickoff@fixture",
            summary: "Project kickoff",
            dtstart: kickoffStart, dtend: kickoffStart.addingTimeInterval(3_600), allDay: false,
            location: "Room 4.12", organizer: EventOrganizer(email: "carla@example.org", cn: "Carla Diaz"),
            attendees: attendees, ownAddress: "me@example.org", sequence: 0, calendarId: calendarId,
            calendarName: "Personal", objectId: eventObjectId, error: nil, ownReply: nil,
            fromAddr: "carla@example.org")

        static let reviewInvitation = Invitation(
            messageId: reviewRowId, method: .cancel, status: .pendingReview, uid: "kickoff@fixture",
            summary: "Project kickoff", dtstart: kickoffStart, dtend: kickoffStart.addingTimeInterval(3_600),
            allDay: false, location: "Room 4.12",
            organizer: EventOrganizer(email: "carla@example.org", cn: "Carla Diaz"),
            attendees: attendees, ownAddress: "me@example.org", sequence: 1, calendarId: calendarId,
            calendarName: "Personal", objectId: reviewObjectId, error: nil, ownReply: nil,
            fromAddr: "organizer@lookalike.example")

        static let event = EventInstance(
            objectId: eventObjectId, recurrenceId: nil, calendarId: calendarId, uid: "kickoff@fixture",
            summary: "Project kickoff", dtstart: kickoffStart, dtend: kickoffStart.addingTimeInterval(3_600),
            tz: "Europe/Berlin", allDay: false, location: "Room 4.12", description: "Agenda to follow.",
            status: .confirmed, sequence: 0, rrule: nil,
            organizer: EventOrganizer(email: "carla@example.org", cn: "Carla Diaz"), attendees: attendees,
            partstat: .needsAction, isRecurring: false, isException: false, pending: false, syncError: nil,
            ownReply: nil, sourceMessageId: invitationRowId, readOnly: false, transparency: .opaque)

        static let minimalPDF = """
            %PDF-1.4
            1 0 obj << /Type /Catalog /Pages 2 0 R >> endobj
            2 0 obj << /Type /Pages /Kids [3 0 R] /Count 1 >> endobj
            3 0 obj << /Type /Page /Parent 2 0 R /MediaBox [0 0 300 200] >> endobj
            trailer << /Root 1 0 R >>
            %%EOF
            """

        static func json<T: Encodable>(_ value: T) -> Data {
            (try? JSONEncoder.mvDefault.encode(value)) ?? Data("{}".utf8)
        }
    }

#endif
