import Foundation

/// Names shared by the notification extension, which writes them, and the app, which reads them
/// back off a delivered or tapped notification.
public enum PushNotificationKeys {
    public static let envelope = "mv"
    public static let blob = "b"

    public static let alertId = "alert_id"
    public static let kind = "kind"
    public static let messageId = "message_id"
    public static let accountId = "account_id"
    public static let url = "url"

    public static let mailKind = "mail"
    /// Carries the Mark as Read action; only a mail alert that names its message gets it.
    public static let mailCategory = "mv.mail"
    public static let markReadAction = "mv.markRead"
}

/// What an alert's envelope carries once opened — the server's `alert_payload`.
public struct PushPayload: Decodable, Sendable, Equatable {
    public let v: Int
    public let alertId: UUID
    public let kind: String
    /// Always present, empty when the alert has none. For a mail alert this is the subject.
    public let title: String
    /// For a mail alert, the sender.
    public let body: String?
    public let accountId: UUID?
    public let messageId: UUID?
    public let folderId: UUID?
    public let url: String?
    /// The icon badge for this device, computed by the server against this device's own scope.
    public let badge: Int
    /// Alerts dismissed elsewhere recently, whose banners should be withdrawn if still showing.
    public let resolved: [UUID]

    enum CodingKeys: String, CodingKey {
        case v, alertId = "alert_id", kind, title, body, accountId = "account_id",
            messageId = "message_id", folderId = "folder_id", url, badge, resolved
    }
}

/// The notification the extension shows for an opened payload.
public struct PushBanner: Sendable, Equatable {
    public let title: String
    public let body: String
    public let threadIdentifier: String?
    public let categoryIdentifier: String?
    public let badge: Int
    public let userInfo: [String: String]

    public init(payload: PushPayload) {
        if payload.kind == PushNotificationKeys.mailKind {
            // Reads like Mail's own banner: who it is from, then what it is about.
            title = payload.body.map(Self.senderName).flatMap { $0.isEmpty ? nil : $0 } ?? "New Mail"
            body = payload.title.isEmpty ? "(no subject)" : payload.title
            categoryIdentifier = payload.messageId == nil ? nil : PushNotificationKeys.mailCategory
        } else {
            title = payload.title.isEmpty ? "MailVerdict" : payload.title
            body = payload.body ?? ""
            categoryIdentifier = nil
        }
        threadIdentifier = payload.accountId?.uuidString.lowercased()
        badge = payload.badge

        var info = [
            PushNotificationKeys.alertId: payload.alertId.uuidString.lowercased(),
            PushNotificationKeys.kind: payload.kind,
        ]
        info[PushNotificationKeys.messageId] = payload.messageId?.uuidString.lowercased()
        info[PushNotificationKeys.accountId] = payload.accountId?.uuidString.lowercased()
        info[PushNotificationKeys.url] = payload.url
        userInfo = info
    }

    /// `Anna Schmidt <anna@example.com>` → `Anna Schmidt`; a bare address stays as it is. A banner
    /// has one line for the sender, and the address is what pushes the name off it.
    static func senderName(_ from: String) -> String {
        let trimmed = from.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasSuffix(">"), let open = trimmed.lastIndex(of: "<") else { return trimmed }
        let name = trimmed[..<open].trimmingCharacters(in: .whitespaces)
            .trimmingCharacters(in: CharacterSet(charactersIn: "\""))
        if name.isEmpty {
            return String(trimmed[trimmed.index(after: open)..<trimmed.index(before: trimmed.endIndex)])
        }
        return name
    }
}

/// A notification currently in Notification Center, reduced to what clearing needs.
public struct DeliveredNotification: Sendable, Equatable {
    public let identifier: String
    public let alertId: UUID?

    public init(identifier: String, alertId: UUID?) {
        self.identifier = identifier
        self.alertId = alertId
    }

    /// Falls back to the request identifier when the extension never added an alert id — a push
    /// whose blob did not open still shows, and the server sends the alert id as its APNs collapse
    /// id, which becomes that identifier.
    public init(identifier: String, userInfo: [AnyHashable: Any]) {
        self.identifier = identifier
        let stored = (userInfo[PushNotificationKeys.alertId] as? String).flatMap(UUID.init(uuidString:))
        self.alertId = stored ?? UUID(uuidString: identifier)
    }
}

public enum PushClearing {
    /// Identifiers of delivered notifications whose alert `isStale` reports as gone. One with no
    /// recognisable alert id is left alone: nothing says which alert it was.
    public static func identifiersToRemove(
        from delivered: [DeliveredNotification], isStale: (UUID) -> Bool
    ) -> [String] {
        delivered.compactMap { notification in
            guard let alertId = notification.alertId, isStale(alertId) else { return nil }
            return notification.identifier
        }
    }
}
