import Foundation

extension MVApiClient {

    /// `before` is the id of the last order of the previous page -- the same cursor shape
    /// `listSpamReview` uses. `favorites` narrows to starred orders; `query` is the server's fuzzy
    /// filter over merchant, subject, status and summary and is omitted when blank.
    public func listOrders(
        state: String = "all", favorites: Bool = false, query: String? = nil, before: UUID? = nil,
        limit: Int = 50
    ) async throws -> OrderListResponse {
        var items: [URLQueryItem] = [
            URLQueryItem(name: "state", value: state), URLQueryItem(name: "limit", value: String(limit)),
        ]
        if favorites { items.append(URLQueryItem(name: "favorites", value: "true")) }
        if let query, !query.isEmpty { items.append(URLQueryItem(name: "q", value: query)) }
        if let before { items.append(URLQueryItem(name: "before", value: before.uuidString)) }
        return try await send(path: "/api/orders", query: items)
    }

    public func getOrder(id: UUID) async throws -> OrderDetail {
        try await send(path: "/api/orders/\(id)")
    }

    /// Flips whichever flags the request names and returns the order as it now stands.
    public func updateOrder(id: UUID, _ update: OrderUpdateRequest) async throws -> OrderDetail {
        try await send(
            path: "/api/orders/\(id)", method: "PATCH", body: try Self.encodeBody(update))
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
    /// Returns the order the mail left, or `nil` (a `204` with no body) when removing it emptied
    /// the order and deleted it -- `send()` can't be used here since it always expects a decodable
    /// body, which a `204` never has.
    public func detachOrderMail(orderId: UUID, mailKey: UUID, moveTo: UUID? = nil) async throws -> OrderDetail? {
        let (data, response) = try await rawSend(
            path: "/api/orders/\(orderId)/mails/\(mailKey)/detach", method: "POST", query: [],
            body: try Self.encodeBody(OrderDetachRequest(moveTo: moveTo)), contentType: "application/json"
        )
        try checkStatus(response: response, data: data)
        guard !data.isEmpty else { return nil }
        do {
            return try JSONDecoder.mvDefault.decode(OrderDetail.self, from: data)
        } catch {
            throw MVError.decoding("\(error)")
        }
    }

    public func catchUpOrders(accountId: UUID, days: Int, dryRun: Bool = false) async throws -> OrderCatchUpResponse {
        try await send(
            path: "/api/orders/catch-up", method: "POST",
            body: try Self.encodeBody(OrderCatchUpRequest(accountId: accountId, days: days, dryRun: dryRun))
        )
    }
}
