import Foundation

extension MVApiClient {

    /// `before` is the id of the last order of the previous page -- the same cursor shape
    /// `listSpamReview` uses.
    public func listOrders(state: String = "all", before: UUID? = nil, limit: Int = 50) async throws
        -> OrderListResponse
    {
        var query: [URLQueryItem] = [
            URLQueryItem(name: "state", value: state), URLQueryItem(name: "limit", value: String(limit)),
        ]
        if let before { query.append(URLQueryItem(name: "before", value: before.uuidString)) }
        return try await send(path: "/api/orders", query: query)
    }

    public func getOrder(id: UUID) async throws -> OrderDetail {
        try await send(path: "/api/orders/\(id)")
    }

    public func deleteOrder(id: UUID) async throws {
        try await sendNoContent(path: "/api/orders/\(id)", method: "DELETE")
    }

    /// Enqueues a manual rewrite -- the order's `text_stale` flag, not this call's response, is
    /// what a screen reads to know a new summary is on its way.
    public func rewriteOrder(id: UUID) async throws {
        try await sendNoContent(path: "/api/orders/\(id)/rewrite", method: "POST")
    }

    public func mergeOrder(id: UUID, into: UUID) async throws -> OrderDetail {
        try await send(
            path: "/api/orders/\(id)/merge", method: "POST", body: try Self.encodeBody(OrderMergeRequest(into: into))
        )
    }

    /// `mailKey` is the mail's own `order_mails.id` (`OrderMailOut.key`), never `messageId`.
    /// Returns the order the mail left, or `nil` when removing it emptied the order and deleted
    /// it.
    public func detachOrderMail(orderId: UUID, mailKey: UUID, moveTo: UUID? = nil) async throws -> OrderDetail? {
        try await send(
            path: "/api/orders/\(orderId)/mails/\(mailKey)/detach", method: "POST",
            body: try Self.encodeBody(OrderDetachRequest(moveTo: moveTo))
        )
    }

    public func catchUpOrders(accountId: UUID, days: Int, dryRun: Bool = false) async throws -> OrderCatchUpResponse {
        try await send(
            path: "/api/orders/catch-up", method: "POST",
            body: try Self.encodeBody(OrderCatchUpRequest(accountId: accountId, days: days, dryRun: dryRun))
        )
    }
}
