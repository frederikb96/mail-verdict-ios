import Foundation
import MailVerdictKit

#if DEBUG

    /// Fixture data for every endpoint `MailboxesScreen` calls — two accounts with an everyday
    /// folder set each, a unified view spanning both, and a bell badge with something in it, so
    /// the Mac workflow's screenshot sweep shows what the screen actually looks like in use:
    /// collapsible account sections, unread badges and a degraded health chip.
    enum MailboxesFixtures {
        static let accountId = UUID(uuidString: "00000000-0000-0000-0000-00000000a001")!
        static let inboxId = UUID(uuidString: "00000000-0000-0000-0000-00000000f001")!
        static let archiveId = UUID(uuidString: "00000000-0000-0000-0000-00000000f002")!
        static let sentId = UUID(uuidString: "00000000-0000-0000-0000-00000000f003")!
        static let glacierId = UUID(uuidString: "00000000-0000-0000-0000-00000000f007")!

        static let accountId2 = UUID(uuidString: "00000000-0000-0000-0000-00000000a002")!
        static let inboxId2 = UUID(uuidString: "00000000-0000-0000-0000-00000000f004")!
        static let archiveId2 = UUID(uuidString: "00000000-0000-0000-0000-00000000f005")!
        static let spamId2 = UUID(uuidString: "00000000-0000-0000-0000-00000000f006")!

        static let unifiedViewId = UUID(uuidString: "00000000-0000-0000-0000-0000000001e1")!

        /// The screen's own store, set from its `.task` — `MVScreenshotEntry.prepare` has no
        /// reach into a screen's `@State`, so this is how it finds the instance to reload once
        /// fixture routes exist. Weak: a screen that goes away must not keep its store alive.
        @MainActor static weak var activeStore: MailboxesStore?

        static func registerIfNeeded() {
            guard MVFixtureLaunch.isEnabled() else { return }

            register(.get, "/api/accounts", [account, account2])
            register(.get, "/api/outbox", [OutboxResponse]())
            register(.get, "/api/alerts/badge", AlertBadgeResponse(count: 3))
            register(.get, "/api/unified/folders", [unifiedFolder])
            register(.get, "/api/accounts/\(accountId)/folder-order", folderOrder)
            register(.get, "/api/accounts/\(accountId)/folders", folders)
            register(.get, "/api/accounts/\(accountId)/sync-status", syncStatus)
            register(.get, "/api/accounts/\(accountId2)/folder-order", folderOrder2)
            register(.get, "/api/accounts/\(accountId2)/folders", folders2)
            register(.get, "/api/accounts/\(accountId2)/sync-status", syncStatus2)
        }

        private static var account: AccountResponse {
            AccountResponse(
                id: accountId, name: "Posteo", imapHost: "posteo.de", imapPort: 993, imapUser: "me@posteo.de",
                smtpHost: "posteo.de", smtpPort: 587, smtpUser: "me@posteo.de", state: "active",
                stateError: nil, capabilities: nil, createdAt: Date(timeIntervalSince1970: 1_700_000_000),
                updatedAt: Date(timeIntervalSince1970: 1_700_000_000), emoji: "📬", folderOrder: nil,
                trashRetentionDays: 30, junkRetentionDays: 30, glacierEnabled: true, glacierFolderId: glacierId,
                glacierAutoDays: 90
            )
        }

        private static var account2: AccountResponse {
            AccountResponse(
                id: accountId2, name: "Fastmail", imapHost: "imap.fastmail.com", imapPort: 993,
                imapUser: "me@fastmail.com", smtpHost: "smtp.fastmail.com", smtpPort: 587,
                smtpUser: "me@fastmail.com", state: "error", stateError: "IMAP connection timed out",
                capabilities: nil, createdAt: Date(timeIntervalSince1970: 1_700_000_000),
                updatedAt: Date(timeIntervalSince1970: 1_700_000_500), emoji: "🚀", folderOrder: nil,
                trashRetentionDays: 30, junkRetentionDays: 30
            )
        }

        private static var folderOrder: FolderOrderResponse {
            FolderOrderResponse(folders: [
                FolderOrderItem(
                    folderId: inboxId, imapName: "INBOX", displayName: "Inbox", specialUse: "inbox",
                    unreadCount: 4, totalCount: 128
                ),
                FolderOrderItem(
                    folderId: archiveId, imapName: "Archive", displayName: "Archive", specialUse: "archive",
                    unreadCount: 0, totalCount: 540
                ),
                FolderOrderItem(
                    folderId: sentId, imapName: "Sent", displayName: "Sent", specialUse: "sent",
                    unreadCount: 0, totalCount: 87
                ),
                FolderOrderItem(
                    folderId: glacierId, imapName: "Glacier", displayName: nil, specialUse: nil,
                    unreadCount: 0, totalCount: 212, kind: "glacier"
                ),
            ])
        }

        private static var folderOrder2: FolderOrderResponse {
            FolderOrderResponse(folders: [
                FolderOrderItem(
                    folderId: inboxId2, imapName: "INBOX", displayName: "Inbox", specialUse: "inbox",
                    unreadCount: 12, totalCount: 342
                ),
                FolderOrderItem(
                    folderId: archiveId2, imapName: "Archive", displayName: "Archive", specialUse: "archive",
                    unreadCount: 0, totalCount: 890
                ),
                FolderOrderItem(
                    folderId: spamId2, imapName: "Spam", displayName: "Spam", specialUse: "junk",
                    unreadCount: 2, totalCount: 15
                ),
            ])
        }

        /// The plain `/folders` list Search's own folder-scope sheet reads — built from the same
        /// `FolderOrderItem`s `folderOrder` carries, so the glacier row appears there too with no
        /// separate definition to drift out of step.
        private static func folders(from order: FolderOrderResponse, accountId: UUID) -> [FolderResponse] {
            order.folders.map { item in
                FolderResponse(
                    id: item.folderId, accountId: accountId, imapName: item.imapName,
                    displayName: item.displayName, specialUse: item.specialUse, mailboxId: nil,
                    initialSyncDone: true, backfillTotal: nil, idleStatus: nil, lastSyncedAt: nil,
                    syncError: nil, createdAt: nil, unreadCount: item.unreadCount, totalCount: item.totalCount,
                    isVisible: item.isVisible, kind: item.kind
                )
            }
        }

        private static var folders: [FolderResponse] { folders(from: folderOrder, accountId: accountId) }
        private static var folders2: [FolderResponse] { folders(from: folderOrder2, accountId: accountId2) }

        private static var syncStatus: SyncStatusResponse {
            SyncStatusResponse(
                accountId: accountId, state: "active", stateError: nil,
                lastFullSync: Date(timeIntervalSince1970: 1_700_000_000),
                lastIncrSync: Date(timeIntervalSince1970: 1_700_000_500), syncTier: "realtime",
                lastError: nil, updatedAt: Date(timeIntervalSince1970: 1_700_000_500)
            )
        }

        /// A `lastFullSync` alongside the account's own `"error"` state is what classifies this
        /// section as `.retrying` rather than `.neverConnected` — a degraded health chip on a
        /// mailbox that has synced before, not a brand-new one still waiting on its first sync.
        private static var syncStatus2: SyncStatusResponse {
            SyncStatusResponse(
                accountId: accountId2, state: "error", stateError: "IMAP connection timed out",
                lastFullSync: Date(timeIntervalSince1970: 1_699_990_000),
                lastIncrSync: Date(timeIntervalSince1970: 1_699_990_500), syncTier: "realtime",
                lastError: "IMAP connection timed out", updatedAt: Date(timeIntervalSince1970: 1_699_990_500)
            )
        }

        private static var unifiedFolder: UnifiedFolderResponse {
            UnifiedFolderResponse(
                id: unifiedViewId, unifiedName: "Everything", emoji: "📥",
                folders: [
                    UnifiedFolderSource(
                        accountId: accountId, accountName: "Posteo", accountEmoji: "📬", folderId: inboxId,
                        imapName: "INBOX", specialUse: "inbox"
                    ),
                    UnifiedFolderSource(
                        accountId: accountId2, accountName: "Fastmail", accountEmoji: "🚀", folderId: inboxId2,
                        imapName: "INBOX", specialUse: "inbox"
                    ),
                ],
                unreadCount: 16, totalCount: 470
            )
        }

        private enum Method: String { case get = "GET" }

        /// Encodes eagerly and captures the resulting `Data`, not `value` itself — `T: Encodable`
        /// says nothing about `Sendable`, and the fixture body closure is `@Sendable`. Caught only
        /// on a Mac compile; `Tooling/swift6-lint.py` has no rule for it yet.
        private static func register<T: Encodable>(_ method: Method, _ path: String, _ value: T) {
            let data = (try? JSONEncoder.mvDefault.encode(value)) ?? Data("[]".utf8)
            MVFixtureURLProtocol.register(method: method.rawValue, path: path) { data }
        }
    }

#endif
