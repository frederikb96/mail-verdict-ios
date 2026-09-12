import Foundation
import MailVerdictKit

#if DEBUG

    /// Fixture data for every endpoint `MailboxesScreen` calls — one account with an everyday
    /// folder set, a unified view spanning it, and a bell badge with something in it, so the Mac
    /// workflow's screenshot sweep has something to show.
    enum MailboxesFixtures {
        static let accountId = UUID(uuidString: "00000000-0000-0000-0000-00000000a001")!
        static let inboxId = UUID(uuidString: "00000000-0000-0000-0000-00000000f001")!
        static let archiveId = UUID(uuidString: "00000000-0000-0000-0000-00000000f002")!
        static let sentId = UUID(uuidString: "00000000-0000-0000-0000-00000000f003")!
        static let unifiedViewId = UUID(uuidString: "00000000-0000-0000-0000-0000000001e1")!

        /// The screen's own store, set from its `.task` — `MVScreenshotEntry.prepare` has no
        /// reach into a screen's `@State`, so this is how it finds the instance to reload once
        /// fixture routes exist. Weak: a screen that goes away must not keep its store alive.
        @MainActor static weak var activeStore: MailboxesStore?

        static func registerIfNeeded() {
            guard MVFixtureLaunch.isEnabled() else { return }

            register(.get, "/api/accounts", account)
            register(.get, "/api/outbox", [OutboxResponse]())
            register(.get, "/api/alerts/badge", AlertBadgeResponse(count: 3))
            register(.get, "/api/unified/folders", [unifiedFolder])
            register(.get, "/api/accounts/\(accountId)/folder-order", folderOrder)
            register(.get, "/api/accounts/\(accountId)/sync-status", syncStatus)
        }

        private static var account: AccountResponse {
            AccountResponse(
                id: accountId, name: "Posteo", imapHost: "posteo.de", imapPort: 993, imapUser: "me@posteo.de",
                smtpHost: "posteo.de", smtpPort: 587, smtpUser: "me@posteo.de", state: "active",
                stateError: nil, capabilities: nil, createdAt: Date(timeIntervalSince1970: 1_700_000_000),
                updatedAt: Date(timeIntervalSince1970: 1_700_000_000), emoji: "📬", folderOrder: nil,
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
            ])
        }

        private static var syncStatus: SyncStatusResponse {
            SyncStatusResponse(
                accountId: accountId, state: "active", stateError: nil,
                lastFullSync: Date(timeIntervalSince1970: 1_700_000_000),
                lastIncrSync: Date(timeIntervalSince1970: 1_700_000_500), syncTier: "realtime",
                lastError: nil, updatedAt: Date(timeIntervalSince1970: 1_700_000_500)
            )
        }

        private static var unifiedFolder: UnifiedFolderResponse {
            UnifiedFolderResponse(
                id: unifiedViewId, unifiedName: "Everything", emoji: "📥",
                folders: [
                    UnifiedFolderSource(
                        accountId: accountId, accountName: "Posteo", accountEmoji: "📬", folderId: inboxId,
                        imapName: "INBOX", specialUse: "inbox"
                    )
                ],
                unreadCount: 4, totalCount: 128
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
