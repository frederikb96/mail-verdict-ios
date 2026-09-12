import Foundation

extension MVApiClient {

    public func listNotifications(
        accountId: UUID, unacknowledgedOnly: Bool = false, limit: Int = 100
    ) async throws -> [NotificationResponse] {
        try await send(
            path: "/api/accounts/\(accountId)/notifications",
            query: [
                URLQueryItem(name: "unacknowledged_only", value: unacknowledgedOnly ? "true" : "false"),
                URLQueryItem(name: "limit", value: String(limit)),
            ]
        )
    }

    public func getUnacknowledgedNotificationCount(accountId: UUID) async throws -> NotificationCountResponse {
        try await send(path: "/api/accounts/\(accountId)/notifications/unacknowledged-count")
    }

    public func acknowledgeNotification(accountId: UUID, notificationId: Int) async throws {
        try await sendNoContent(
            path: "/api/accounts/\(accountId)/notifications/\(notificationId)/ack", method: "POST"
        )
    }

    public func acknowledgeAllNotifications(accountId: UUID) async throws {
        try await sendNoContent(path: "/api/accounts/\(accountId)/notifications/ack-all", method: "POST")
    }

    /// Cross-account, every account including inactive ones. Without it the System tab and
    /// every background wake would pay one request per account.
    public func listAllNotifications(
        unacknowledgedOnly: Bool = false, limit: Int = 100
    ) async throws -> [NotificationResponse] {
        try await send(
            path: "/api/notifications",
            query: [
                URLQueryItem(name: "unacknowledged_only", value: unacknowledgedOnly ? "true" : "false"),
                URLQueryItem(name: "limit", value: String(limit)),
            ]
        )
    }
}
