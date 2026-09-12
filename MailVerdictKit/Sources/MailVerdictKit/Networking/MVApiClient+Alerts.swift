import Foundation

extension MVApiClient {

    public func listAlerts(
        limit: Int = 50, folderIds: [UUID]? = nil, unseenOnly: Bool = false
    ) async throws -> [AlertResponse] {
        var query: [URLQueryItem] = [URLQueryItem(name: "limit", value: String(limit))]
        if let folderIds {
            folderIds.forEach { query.append(URLQueryItem(name: "folder_ids", value: $0.uuidString)) }
            query.append(URLQueryItem(name: "folder_scoped", value: "true"))
        }
        if unseenOnly { query.append(URLQueryItem(name: "unseen_only", value: "true")) }
        return try await send(path: "/api/alerts", query: query)
    }

    public func getUnseenAlertCount(folderIds: [UUID]? = nil) async throws -> AlertUnseenCountResponse {
        var query: [URLQueryItem] = []
        if let folderIds {
            folderIds.forEach { query.append(URLQueryItem(name: "folder_ids", value: $0.uuidString)) }
            query.append(URLQueryItem(name: "folder_scoped", value: "true"))
        }
        return try await send(path: "/api/alerts/unseen-count", query: query)
    }

    public func dismissAlert(id: UUID) async throws {
        try await sendNoContent(path: "/api/alerts/\(id)/dismiss", method: "POST")
    }

    public func dismissAllAlerts(kinds: [String] = []) async throws {
        var query: [URLQueryItem] = []
        kinds.forEach { query.append(URLQueryItem(name: "kind", value: $0)) }
        try await sendNoContent(path: "/api/alerts/dismiss-all", method: "POST", query: query)
    }

    public func listPushSubscriptions() async throws -> [PushSubscriptionResponse] {
        try await send(path: "/api/alerts/subscriptions")
    }

    public func updatePushSubscription(
        id: UUID, _ request: PushSubscriptionUpdate
    ) async throws -> PushSubscriptionResponse {
        try await send(
            path: "/api/alerts/subscriptions/\(id)", method: "PATCH", body: try Self.encodeBody(request)
        )
    }

    public func deletePushSubscription(id: UUID) async throws {
        try await sendNoContent(path: "/api/alerts/subscriptions/\(id)", method: "DELETE")
    }

    // MARK: Native push (systems §5.05)

    public func getNativePushConfig() async throws -> NativePushConfigResponse {
        try await send(path: "/api/alerts/native-push")
    }

    public func registerNativePushSubscription(
        _ request: NativeSubscriptionCreate
    ) async throws -> PushSubscriptionResponse {
        try await send(
            path: "/api/alerts/subscriptions/native", method: "POST", body: try Self.encodeBody(request)
        )
    }

    public func testPushSubscription(id: UUID) async throws {
        try await sendNoContent(path: "/api/alerts/subscriptions/\(id)/test", method: "POST")
    }

    public func lookupAlerts(ids: [UUID]) async throws -> [AlertResponse] {
        try await send(
            path: "/api/alerts/lookup", method: "POST", body: try Self.encodeBody(AlertLookupRequest(ids: ids))
        )
    }

    /// Either a registered device's own scope (`subscriptionId`) or an explicit folder scope —
    /// the same two ways `list_for_alert` itself resolves "which folders alert" (systems §5.05).
    public func getAlertBadge(subscriptionId: UUID) async throws -> AlertBadgeResponse {
        try await send(
            path: "/api/alerts/badge",
            query: [URLQueryItem(name: "subscription_id", value: subscriptionId.uuidString)]
        )
    }

    public func getAlertBadge(folderIds: [UUID]?) async throws -> AlertBadgeResponse {
        var query: [URLQueryItem] = [URLQueryItem(name: "folder_scoped", value: "true")]
        folderIds?.forEach { query.append(URLQueryItem(name: "folder_ids", value: $0.uuidString)) }
        return try await send(path: "/api/alerts/badge", query: query)
    }
}
