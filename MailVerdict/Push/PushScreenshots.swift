#if DEBUG

    import Foundation
    import MailVerdictKit
    import Push

    /// The New Mail Notifications screen in each state a person meets it in. Each entry's prepare
    /// step installs the server's answers and the system permission for that state, then reloads
    /// the screen's own store before the screen reports ready.
    enum PushScreenshots {
        static let entries: [MVScreenshotEntry] = [
            entry("push-settings-registered", .registered),
            entry("push-settings-allow", .allow),
            entry("push-settings-denied", .denied),
            entry("push-settings-unavailable", .unavailable),
        ]

        private static func entry(_ id: String, _ state: PushSettingsFixture.Variant) -> MVScreenshotEntry {
            MVScreenshotEntry(id: id, destination: .route(.notificationSettings)) { environment, connection in
                PushSettingsFixture.install(state, serverOrigin: PushCoordinator.serverOrigin(environment))
                await PushCoordinator.shared.settingsStore(environment: environment, connection: connection).reload()
            }
        }
    }

    /// Two accounts, this phone, a browser and a phone the relay reported gone.
    enum PushSettingsFixture {
        enum Variant: Sendable {
            case registered, allow, denied, unavailable
        }

        private static func id(_ n: Int) -> UUID {
            UUID(uuidString: String(format: "6f1c2a3b-0000-4000-8000-%012d", n))!
        }

        private static let work = id(1)
        private static let personal = id(2)
        private static let thisPhone = id(10)

        @MainActor
        static func install(_ state: Variant, serverOrigin: String) {
            let now = Date()
            let records = PushRecordStore()
            switch state {
            case .registered:
                PushCoordinator.shared.fixtureAuthorization = .authorized
                records.save(
                    PushRegistrationRecord(
                        isEnabled: true, subscriptionId: thisPhone, apnsToken: "fixture",
                        ticketExpiresAt: now.addingTimeInterval(80 * 86_400), lastUpsertAt: now),
                    serverOrigin: serverOrigin)
            case .allow:
                PushCoordinator.shared.fixtureAuthorization = .notDetermined
                records.save(PushRegistrationRecord(), serverOrigin: serverOrigin)
            case .denied:
                PushCoordinator.shared.fixtureAuthorization = .denied
                records.save(PushRegistrationRecord(), serverOrigin: serverOrigin)
            case .unavailable:
                PushCoordinator.shared.fixtureAuthorization = .authorized
                records.save(PushRegistrationRecord(), serverOrigin: serverOrigin)
            }

            serve(
                "/api/alerts/native-push",
                state == .unavailable
                    ? NativePushConfigResponse(
                        available: false, relayUrls: [], reason: "Native push needs ENCRYPTION_KEY set on the server.")
                    : NativePushConfigResponse(
                        available: true, relayUrls: [PushRegistrationService.relayURL], reason: nil))
            serve("/api/alerts/subscriptions", devices(now: now, includingThisPhone: state == .registered))
            serve("/api/accounts", [account(work, "Work", now), account(personal, "Personal", now)])
            serve(
                "/api/accounts/\(work)/folders",
                [
                    folder(id(20), work, "INBOX", "Inbox", "inbox"),
                    folder(id(21), work, "Newsletters", nil, nil),
                    folder(id(22), work, "Sent", "Sent", "sent"),
                    folder(id(23), work, "Trash", "Trash", "trash"),
                ])
            serve(
                "/api/accounts/\(personal)/folders",
                [
                    folder(id(24), personal, "INBOX", "Inbox", "inbox"),
                    folder(id(25), personal, "Archive", "Archive", "archive"),
                ])
        }

        private static func devices(now: Date, includingThisPhone: Bool) -> [PushSubscriptionResponse] {
            var devices = [
                PushSubscriptionResponse(
                    id: id(11), transport: .webpush, label: "Firefox on Linux", alertFolderIds: nil,
                    remindersEnabled: false, createdAt: now.addingTimeInterval(-40 * 86_400),
                    lastSeenAt: now.addingTimeInterval(-3 * 3_600), failedAt: nil),
                PushSubscriptionResponse(
                    id: id(12), transport: .apns, label: "Old iPhone", alertFolderIds: nil, remindersEnabled: false,
                    createdAt: now.addingTimeInterval(-300 * 86_400), lastSeenAt: now.addingTimeInterval(-9 * 86_400),
                    failedAt: now.addingTimeInterval(-2 * 86_400)),
            ]
            if includingThisPhone {
                devices.insert(
                    PushSubscriptionResponse(
                        id: thisPhone, transport: .apns, label: "iPhone", alertFolderIds: nil, remindersEnabled: false,
                        mutedChannels: ["system"], createdAt: now.addingTimeInterval(-86_400), lastSeenAt: now,
                        failedAt: nil),
                    at: 0)
            }
            return devices
        }

        private static func account(_ id: UUID, _ name: String, _ now: Date) -> AccountResponse {
            AccountResponse(
                id: id, name: name, imapHost: "imap.example.com", imapPort: 993, imapUser: name.lowercased(),
                smtpHost: nil, smtpPort: nil, smtpUser: nil, stateError: nil, capabilities: nil, createdAt: now,
                updatedAt: now, emoji: nil, folderOrder: nil, trashRetentionDays: nil, junkRetentionDays: nil)
        }

        private static func folder(
            _ id: UUID, _ account: UUID, _ imapName: String, _ displayName: String?, _ specialUse: String?
        ) -> FolderResponse {
            FolderResponse(
                id: id, accountId: account, imapName: imapName, displayName: displayName, specialUse: specialUse,
                mailboxId: nil, backfillTotal: nil, idleStatus: nil, lastSyncedAt: nil, syncError: nil,
                createdAt: nil)
        }

        private static func serve(_ path: String, _ value: some Encodable) {
            let data = (try? JSONEncoder.mvDefault.encode(value)) ?? Data("null".utf8)
            MVFixtureURLProtocol.register(method: "GET", path: path) { data }
        }
    }

#endif
