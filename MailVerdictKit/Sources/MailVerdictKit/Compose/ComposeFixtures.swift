#if DEBUG

    import Foundation

    /// Fixture-mode data for the composer: one account with two sending identities, and a message
    /// to reply to with its quote. Built from the real model types and encoded the way the client
    /// decodes, so a fixture cannot drift from what the composer reads.
    public enum ComposeFixtures {

        public static let accountId = UUID(uuidString: "C0000000-0000-4000-8000-000000000001")!
        public static let messageId = UUID(uuidString: "C0000000-0000-4000-8000-000000000002")!

        private static let date = Date(timeIntervalSince1970: 1_757_000_000)

        public static var accounts: [AccountResponse] {
            [
                AccountResponse(
                    id: accountId, name: "Posteo", imapHost: "posteo.de", imapPort: 993, imapUser: "me@example.com",
                    smtpHost: "posteo.de", smtpPort: 465, smtpUser: "me@example.com", isActive: true, state: "active",
                    stateError: nil, capabilities: nil, createdAt: date, updatedAt: date, emoji: nil, folderOrder: nil,
                    trashRetentionDays: nil, junkRetentionDays: nil)
            ]
        }

        public static var identities: [IdentityResponse] {
            [
                IdentityResponse(
                    id: UUID(uuidString: "C0000000-0000-4000-8000-000000000011")!, accountId: accountId,
                    address: "me@example.com", displayName: "Alex Example", isDefault: true, createdAt: date),
                IdentityResponse(
                    id: UUID(uuidString: "C0000000-0000-4000-8000-000000000012")!, accountId: accountId,
                    address: "hello@example.com", displayName: "Alex Example", isDefault: false, createdAt: date),
            ]
        }

        public static var message: MessageDetail {
            MessageDetail(
                id: messageId, accountId: accountId,
                folderId: UUID(uuidString: "C0000000-0000-4000-8000-000000000021")!,
                threadId: UUID(uuidString: "C0000000-0000-4000-8000-000000000022")!, subject: "Dinner on Friday",
                fromAddr: "Ann Example <ann@example.com>", toAddrs: .array(["me@example.com"]), receivedAt: date,
                isSeen: true, snippet: "Are we still on for Friday?", messageId: "<dinner-1@example.com>",
                ccAddrs: .array(["sam@example.com"]), bccAddrs: nil, replyTo: nil, inReplyTo: nil, references: nil,
                bodyText: "Hi!\n\nAre we still on for Friday? I booked a table for 7.\n\nAnn",
                bodyHtml: nil, sizeBytes: 2048, createdAt: date, verdict: nil)
        }

        public static let quoteHTML =
            "<p>Hi!</p><p>Are we still on for Friday? I booked a table for 7.</p><p>Ann</p>"

        public static var contactHits: [ContactSearchHitOut] {
            [
                ContactSearchHitOut(
                    contactId: UUID(uuidString: "C0000000-0000-4000-8000-000000000031")!, name: "Ann Example",
                    email: "ann@example.com", source: "carddav")
            ]
        }

        /// Every route the composer calls, with the path exactly as `MVApiClient` builds it.
        public static var routes: [(path: String, body: Data)] {
            let encoder = JSONEncoder.mvDefault
            return [
                ("/api/accounts", (try? encoder.encode(accounts)) ?? Data()),
                ("/api/identities", (try? encoder.encode(identities)) ?? Data()),
                ("/api/messages/\(messageId)", (try? encoder.encode(message)) ?? Data()),
                (
                    "/api/messages/\(messageId)/quote",
                    (try? encoder.encode(MessageQuoteResponse(html: quoteHTML))) ?? Data()
                ),
                ("/api/contacts/search", (try? encoder.encode(contactHits)) ?? Data()),
            ]
        }

        public static func register() {
            for route in routes {
                let body = route.body
                MVFixtureURLProtocol.register(method: "GET", path: route.path) { body }
            }
        }
    }

#endif
