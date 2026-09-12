import Foundation
import MailVerdictKit

#if DEBUG

    /// Fixture data for the Notifications screen's own screenshot sweep — one mail alert, one
    /// write-failure notification.
    enum NotificationsFixtures {
        static func registerIfNeeded() {
            guard MVFixtureLaunch.isEnabled() else { return }
            MailboxesFixtures.registerIfNeeded()
            register(.get, "/api/alerts", alerts)
            register(.get, "/api/notifications", notifications)
        }

        private static var alerts: [AlertResponse] {
            [
                AlertResponse(
                    id: UUID(uuidString: "00000000-0000-0000-0000-0000000071a1")!, kind: "mail",
                    title: "New message from Alex", body: "Let's catch up tomorrow", url: nil,
                    accountId: MailboxesFixtures.accountId, messageId: UUID(), folderId: MailboxesFixtures.inboxId,
                    deliveredAt: Date(timeIntervalSinceNow: -300), dismissedAt: nil,
                    createdAt: Date(timeIntervalSinceNow: -300)
                )
            ]
        }

        private static var notifications: [NotificationResponse] {
            [
                NotificationResponse(
                    id: 1, accountId: MailboxesFixtures.accountId, action: "move", messageId: UUID(), folderId: nil,
                    outboxId: nil, error: "IMAP server timed out", detail: nil, acknowledgedAt: nil,
                    revertedAt: nil, createdAt: Date(timeIntervalSinceNow: -600)
                )
            ]
        }

        private enum Method: String { case get = "GET" }

        private static func register<T: Encodable>(_ method: Method, _ path: String, _ value: T) {
            MVFixtureURLProtocol.register(method: method.rawValue, path: path) {
                (try? JSONEncoder.mvDefault.encode(value)) ?? Data("[]".utf8)
            }
        }
    }

#endif
