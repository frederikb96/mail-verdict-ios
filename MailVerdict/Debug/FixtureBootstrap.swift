import Foundation
import MailVerdictKit

#if DEBUG

    /// Turns fixture mode on for this launch, if `-MVFixtureMode` asked for it.
    ///
    /// Four things have to happen before `RootView` is ever built, and all four happen here
    /// rather than in `AppEnvironment` or `RootView` themselves, so neither needs to know fixture
    /// mode exists:
    /// - register the URL protocol that answers every request from the fixture table
    /// - plant a base URL in `UserDefaults`, so `AppEnvironment.init()`'s own `connect()` has
    ///   something to build `MVRequestFactory` from — without one it fails `emptyBaseURL` and
    ///   silently leaves the gate at `.needsConfiguration`, sign-in screen and all
    /// - plant a credential in the Keychain, so `AppEnvironment.init()` finds one already there
    ///   and connects on its own — exactly the path a real sign-in takes, just pre-seeded
    /// - register the shell-level baseline (`registerShellBaseline`) every screenshot needs
    ///   answered regardless of which one is on top
    ///
    /// Reuses `MVKeychainCredentialStore` rather than writing to the Keychain independently: it is
    /// `internal` and this file compiles into the same app target, so the query attributes
    /// (service, account, `kSecAttrSynchronizable`) stay defined in exactly the one place that
    /// already owns them.
    enum FixtureBootstrap {
        /// Never dialed — `MVFixtureURLProtocol` answers every request before it reaches the
        /// network — so only its shape (a scheme `MVRequestFactory` accepts) matters.
        private static let placeholderBackendURL = "https://fixture.invalid"

        /// Not a credential — nothing it authenticates ever leaves the process, since
        /// `MVFixtureURLProtocol` answers every request before it reaches the network. Only its
        /// presence matters: `AppEnvironment.init()` reads the Keychain and connects if it finds
        /// anything there.
        private static let placeholderCredential = MVAuthMode.bearer(token: "fixture-mode-token")

        static func installIfRequested() {
            guard MVFixtureLaunch.isEnabled() else { return }
            URLProtocol.registerClass(MVFixtureURLProtocol.self)
            UserDefaults.standard.set(placeholderBackendURL, forKey: AppEnvironment.backendURLKey)
            MVKeychainCredentialStore().write(placeholderCredential)
            registerShellBaseline()
        }

        // MARK: - Shell-level baseline

        private static let accountId1 = UUID(uuidString: "00000000-0000-0000-0000-0000000b0001")!
        private static let accountId2 = UUID(uuidString: "00000000-0000-0000-0000-0000000b0002")!

        /// Mailboxes is the `NavigationStack`'s root, so it stays mounted — and its own `.task`
        /// keeps loading — underneath whatever screen a sweep actually pushed on top; the
        /// undo-send capsule and the live-event hub are the same way, always present regardless
        /// of screen. Every request one of those always-on pieces makes gets answered here with
        /// benign, contract-valid data, registered before any screen's own `prepare` runs — which
        /// is what lets a screen needing something different just call
        /// `MVFixtureURLProtocol.register` again for the same path in its own `prepare` and win,
        /// `register`'s own later-wins rule doing the overriding with no extra code.
        private static func registerShellBaseline() {
            let now = Date(timeIntervalSince1970: 1_700_000_000)

            let accounts = [
                AccountResponse(
                    id: accountId1, name: "Posteo", imapHost: "imap.example.com", imapPort: 993,
                    imapUser: "posteo", smtpHost: "smtp.example.com", smtpPort: 587, smtpUser: "posteo",
                    state: "active", stateError: nil, capabilities: nil, createdAt: now, updatedAt: now,
                    emoji: "📬", folderOrder: nil, trashRetentionDays: 30, junkRetentionDays: 30
                ),
                AccountResponse(
                    id: accountId2, name: "Work", imapHost: "imap.example.com", imapPort: 993,
                    imapUser: "work", smtpHost: "smtp.example.com", smtpPort: 587, smtpUser: "work",
                    state: "active", stateError: nil, capabilities: nil, createdAt: now, updatedAt: now,
                    emoji: "💼", folderOrder: nil, trashRetentionDays: 30, junkRetentionDays: 30
                ),
            ]

            let folders1 = FolderOrderResponse(folders: [
                FolderOrderItem(
                    folderId: UUID(uuidString: "00000000-0000-0000-0000-00000001f001")!, imapName: "INBOX",
                    displayName: "Inbox", specialUse: "inbox", unreadCount: 0, totalCount: 0
                ),
                FolderOrderItem(
                    folderId: UUID(uuidString: "00000000-0000-0000-0000-00000001f002")!, imapName: "Archive",
                    displayName: "Archive", specialUse: "archive", unreadCount: 0, totalCount: 0
                ),
                FolderOrderItem(
                    folderId: UUID(uuidString: "00000000-0000-0000-0000-00000001f003")!, imapName: "Sent",
                    displayName: "Sent", specialUse: "sent", unreadCount: 0, totalCount: 0
                ),
            ])
            let folders2 = FolderOrderResponse(folders: [
                FolderOrderItem(
                    folderId: UUID(uuidString: "00000000-0000-0000-0000-00000002f001")!, imapName: "INBOX",
                    displayName: "Inbox", specialUse: "inbox", unreadCount: 0, totalCount: 0
                ),
                FolderOrderItem(
                    folderId: UUID(uuidString: "00000000-0000-0000-0000-00000002f002")!, imapName: "Archive",
                    displayName: "Archive", specialUse: "archive", unreadCount: 0, totalCount: 0
                ),
                FolderOrderItem(
                    folderId: UUID(uuidString: "00000000-0000-0000-0000-00000002f003")!, imapName: "Sent",
                    displayName: "Sent", specialUse: "sent", unreadCount: 0, totalCount: 0
                ),
            ])

            let syncStatus1 = SyncStatusResponse(
                accountId: accountId1, state: "active", stateError: nil, lastFullSync: now,
                lastIncrSync: now, syncTier: "realtime", lastError: nil, updatedAt: now
            )
            let syncStatus2 = SyncStatusResponse(
                accountId: accountId2, state: "active", stateError: nil, lastFullSync: now,
                lastIncrSync: now, syncTier: "realtime", lastError: nil, updatedAt: now
            )

            let identities = [
                IdentityResponse(
                    id: UUID(), accountId: accountId1, address: "me@posteo.de", displayName: nil,
                    isDefault: true, createdAt: now
                ),
                IdentityResponse(
                    id: UUID(), accountId: accountId2, address: "me@work.example", displayName: nil,
                    isDefault: true, createdAt: now
                ),
            ]

            register(.get, "/api/accounts", accounts)
            register(.get, "/api/accounts/\(accountId1)/folder-order", folders1)
            register(.get, "/api/accounts/\(accountId2)/folder-order", folders2)
            register(.get, "/api/accounts/\(accountId1)/sync-status", syncStatus1)
            register(.get, "/api/accounts/\(accountId2)/sync-status", syncStatus2)
            register(.get, "/api/unified/folders", [UnifiedFolderResponse]())
            register(.get, "/api/outbox", [OutboxResponse]())
            register(.get, "/api/outbox/pending", [PendingSendResponse]())
            register(.get, "/api/alerts/badge", AlertBadgeResponse(count: 0))
            register(.get, "/api/alerts", [AlertResponse]())
            register(.get, "/api/notifications", [NotificationResponse]())
            register(
                .get, "/api/alerts/native-push",
                NativePushConfigResponse(available: false, relayUrls: [], reason: "fixture mode")
            )
            register(.get, "/api/contacts/photo-index", ContactPhotoIndexResponse(byEmail: [:], partial: false))
            register(.get, "/api/identities", identities)

            // An ordinary fixture response finishes loading the instant it is delivered, which
            // `MVSseClient` reads as the connection dropping the moment it came up — sending it
            // into its own reconnect-with-backoff loop for the rest of the run. `keepOpen` leaves
            // this one "open": the client sees `.connected` and one keepalive comment (the same
            // shape the real backend sends), nothing else, for as long as the process lives.
            MVFixtureURLProtocol.register(method: "GET", path: "/api/events", keepOpen: true) {
                Data(": keepalive\n\n".utf8)
            }
        }

        private enum Method: String { case get = "GET" }

        /// Encodes eagerly and captures the resulting `Data`, not `value` itself — `T: Encodable`
        /// says nothing about `Sendable`, and the fixture body closure is `@Sendable`.
        private static func register<T: Encodable>(_ method: Method, _ path: String, _ value: T) {
            let data = (try? JSONEncoder.mvDefault.encode(value)) ?? Data("[]".utf8)
            MVFixtureURLProtocol.register(method: method.rawValue, path: path) { data }
        }
    }

#endif
