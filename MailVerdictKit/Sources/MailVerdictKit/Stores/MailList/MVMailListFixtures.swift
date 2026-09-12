#if DEBUG

    import Foundation

    /// A folder of fixture mail for the list screen's screenshot sweep — every endpoint the list,
    /// its select mode and its Move picker call, built from the real models and encoded with the
    /// real encoder, so a fixture can never drift from what the client decodes.
    public enum MVMailListFixtures {
        public static let accountId = UUID(uuidString: "00000000-0000-0000-0000-0000000a0001")!
        public static let folderId = UUID(uuidString: "00000000-0000-0000-0000-0000000f0001")!
        public static let scope = ListScope.folder(accountId: accountId, folderId: folderId)

        static let trashId = UUID(uuidString: "00000000-0000-0000-0000-0000000f0002")!
        static let archiveId = UUID(uuidString: "00000000-0000-0000-0000-0000000f0003")!
        static let projectsId = UUID(uuidString: "00000000-0000-0000-0000-0000000f0004")!

        /// Registers every route. Answers are computed per request, so relative dates stay
        /// relative to whenever the screen is shown.
        public static func register() {
            route("/api/accounts/\(accountId)/messages") { messages(now: Date()) }
            route("/api/accounts") { [account] }
            route("/api/accounts/\(accountId)/folders") { folders(now: Date()) }
            route("/api/accounts/\(accountId)/folder-order") { folderOrder }
            route("/api/accounts/\(accountId)/messages/selection") {
                SelectionSnapshotResponse(snapshotAt: Date(), count: 128)
            }
            route("/api/outbox") { [OutboxResponse]() }
            route("/api/unified/folders") { [UnifiedFolderResponse]() }
            route("/api/search") {
                SearchResponse(results: [], hasMore: false, nextCursor: nil, query: "", total: 0)
            }
        }

        private static func route<T: Encodable & Sendable>(_ path: String, _ body: @escaping @Sendable () -> T) {
            MVFixtureURLProtocol.register(method: "GET", path: path) {
                (try? JSONEncoder.mvDefault.encode(body())) ?? Data("{}".utf8)
            }
        }

        static let account = AccountResponse(
            id: accountId, name: "Posteo", imapHost: "posteo.de", imapPort: 993, imapUser: "reader@example.com",
            smtpHost: "posteo.de", smtpPort: 465, smtpUser: "reader@example.com", state: "active", stateError: nil,
            capabilities: nil, createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            updatedAt: Date(timeIntervalSince1970: 1_700_000_000), emoji: "📮", folderOrder: nil,
            trashRetentionDays: nil, junkRetentionDays: nil
        )

        static func folders(now: Date) -> [FolderResponse] {
            let specs: [(UUID, String, String?, Int, Int)] = [
                (folderId, "INBOX", "inbox", 6, 128), (trashId, "Trash", "trash", 0, 12),
                (archiveId, "Archive", "archive", 0, 940), (projectsId, "Projects", nil, 2, 31),
            ]
            return specs.map { id, name, specialUse, unread, total in
                FolderResponse(
                    id: id, accountId: accountId, imapName: name, displayName: nil, specialUse: specialUse,
                    mailboxId: nil, initialSyncDone: true, backfillTotal: nil, idleStatus: nil,
                    lastSyncedAt: now.addingTimeInterval(-120), syncError: nil, createdAt: nil, unreadCount: unread,
                    totalCount: total
                )
            }
        }

        static let folderOrder = FolderOrderResponse(
            folders: [
                FolderOrderItem(folderId: folderId, imapName: "INBOX", displayName: nil, specialUse: "inbox"),
                FolderOrderItem(folderId: projectsId, imapName: "Projects", displayName: nil, specialUse: nil),
                FolderOrderItem(folderId: archiveId, imapName: "Archive", displayName: nil, specialUse: "archive"),
                FolderOrderItem(folderId: trashId, imapName: "Trash", displayName: nil, specialUse: "trash"),
            ]
        )

        private static let senders = [
            ("Ada Lovelace", "ada@analytical.example"), ("Hetzner Online", "billing@hetzner.example"),
            ("GitHub", "noreply@github.example"), ("Grace Hopper", "grace@navy.example"),
            ("Deutsche Bahn", "service@bahn.example"), ("Linus", "linus@kernel.example"),
            ("Posteo", "team@posteo.example"), ("Alan Turing", "alan@bletchley.example"),
        ]

        private static let subjects = [
            "Notes on the Analytical Engine", "Your invoice for September", "[mail-verdict] CI passed on main",
            "Compiler meeting moved to Thursday", "Your ticket: Aachen → Berlin", "Re: patch review",
            "Mailbox storage upgraded", "Lunch next week?",
        ]

        private static let snippets = [
            "I have attached the corrected tables. The second set of operations now repeats as expected, which "
                + "should make the Bernoulli example much easier to follow.",
            "Thank you for your order. The invoice for the current period is attached as a PDF.",
            "All checks have passed for the latest push.",
            "Could we move the meeting to Thursday afternoon? Tuesday no longer works for most of the team.",
            "Your booking is confirmed. Seat reservations are included.",
            "Looks good to me overall, a few nits inline.",
            "We have doubled the storage of your mailbox at no extra cost.",
            "Are you around next week? There is a new place near the cathedral worth trying.",
        ]

        static func messages(now: Date) -> MessageListResponse {
            let rows = (0..<36).map { index -> MessageSummary in
                let sender = senders[index % senders.count]
                return MessageSummary(
                    id: UUID(uuidString: String(format: "00000000-0000-0000-0000-0000001%05d", index))!,
                    accountId: accountId, folderId: folderId,
                    threadId: UUID(uuidString: String(format: "00000000-0000-0000-0000-0000002%05d", index))!,
                    subject: subjects[index % subjects.count], fromAddr: "\(sender.0) <\(sender.1)>", toAddrs: nil,
                    receivedAt: now.addingTimeInterval(-Double(index) * 5_400 - 600), isSeen: index % 5 >= 2,
                    isFlagged: index % 7 == 1, isAnswered: index % 6 == 3, snippet: snippets[index % snippets.count],
                    threadCount: index % 4 == 0 ? 3 : 1, unreadInThread: index % 5 >= 2 ? 0 : 1,
                    mirroredAt: now.addingTimeInterval(-Double(index) * 5_400), hasAttachments: index % 3 == 1,
                    verdictIsSpam: index == 9 ? true : false
                )
            }
            return MessageListResponse(messages: rows, hasMore: false, nextCursor: nil)
        }
    }

#endif
