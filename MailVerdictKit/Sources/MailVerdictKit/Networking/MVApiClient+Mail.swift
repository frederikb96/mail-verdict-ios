import Foundation

#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif

extension MVApiClient {

    // MARK: List

    public func listMessages(
        accountId: UUID, folderId: UUID? = nil, threaded: Bool = false, isSeen: Bool? = nil,
        since: Date? = nil, before: UUID? = nil, after: UUID? = nil, around: UUID? = nil,
        limit: Int = 50
    ) async throws -> MessageListResponse {
        var query: [URLQueryItem] = [URLQueryItem(name: "threaded", value: threaded ? "true" : "false")]
        if let folderId { query.append(URLQueryItem(name: "folder_id", value: folderId.uuidString)) }
        if let isSeen { query.append(URLQueryItem(name: "is_seen", value: isSeen ? "true" : "false")) }
        if let since { query.append(URLQueryItem(name: "since", value: MVDateFormatting.format(since))) }
        if let before { query.append(URLQueryItem(name: "before", value: before.uuidString)) }
        if let after { query.append(URLQueryItem(name: "after", value: after.uuidString)) }
        if let around { query.append(URLQueryItem(name: "around", value: around.uuidString)) }
        query.append(URLQueryItem(name: "limit", value: String(limit)))
        return try await send(path: "/api/accounts/\(accountId)/messages", query: query)
    }

    public func getMessage(id: UUID, loadImages: Bool = false, timeout: TimeInterval? = nil) async throws
        -> MessageDetail
    {
        try await send(
            path: "/api/messages/\(id)",
            query: [URLQueryItem(name: "load_images", value: loadImages ? "true" : "false")], timeout: timeout
        )
    }

    public func getThread(
        messageId: UUID, loadImages: Bool = true, timeout: TimeInterval? = nil
    ) async throws -> ThreadResponse {
        try await send(
            path: "/api/messages/\(messageId)/thread",
            query: [URLQueryItem(name: "load_images", value: loadImages ? "true" : "false")], timeout: timeout
        )
    }

    public func locateMessage(id: UUID, timeout: TimeInterval? = nil) async throws -> MessageLocation {
        try await send(path: "/api/messages/\(id)/location", timeout: timeout)
    }

    public func getMessageQuote(id: UUID) async throws -> MessageQuoteResponse {
        try await send(path: "/api/messages/\(id)/quote")
    }

    /// The message's full RFC822 source, for the reader's "Share Message File…" and `.eml`
    /// download. 409 (no raw source stored — truncated or never fetched) reaches the caller as an
    /// ordinary `MVError`, not a special case this method swallows.
    public func getRawMessage(id: UUID) async throws -> (data: Data, suggestedFilename: String?) {
        let result = try await sendRaw(path: "/api/messages/\(id)/raw")
        return (result.data, result.suggestedFilename)
    }

    public func getAttachment(messageId: UUID, attachmentId: UUID) async throws -> (
        data: Data, contentType: String?, suggestedFilename: String?
    ) {
        try await sendRaw(path: "/api/messages/\(messageId)/attachments/\(attachmentId)")
    }

    // MARK: Action (single message)

    public func performMessageAction(
        messageId: UUID, action: MVMessageAction, targetFolderId: UUID? = nil, keyword: String? = nil,
        idempotencyKey: UUID? = nil, expectedFolderId: UUID? = nil, timeout: TimeInterval? = nil
    ) async throws -> MessageActionResponse {
        let request = MessageActionRequest(
            action: action, targetFolderId: targetFolderId, keyword: keyword, idempotencyKey: idempotencyKey,
            expectedFolderId: expectedFolderId)
        return try await send(
            path: "/api/messages/\(messageId)/action", method: "POST",
            body: try Self.encodeBody(request), timeout: timeout
        )
    }

    // MARK: Selection + bulk action (an account's own messages)

    public func mintSelection(
        accountId: UUID, folderId: UUID, filter: String = "all"
    ) async throws -> SelectionSnapshotResponse {
        try await send(
            path: "/api/accounts/\(accountId)/messages/selection",
            query: [
                URLQueryItem(name: "folder_id", value: folderId.uuidString),
                URLQueryItem(name: "filter", value: filter),
            ]
        )
    }

    public func bulkAction(
        accountId: UUID, request: BulkActionRequest, timeout: TimeInterval? = nil
    ) async throws -> BulkActionResponse {
        try await send(
            path: "/api/accounts/\(accountId)/messages/bulk-action", method: "POST",
            body: try Self.encodeBody(request), timeout: timeout
        )
    }

    // MARK: Unified (across accounts)

    public func listUnifiedMessages(
        viewName: String, threaded: Bool = false, isSeen: Bool? = nil, since: Date? = nil,
        before: UUID? = nil, after: UUID? = nil, around: UUID? = nil, limit: Int = 50
    ) async throws -> MessageListResponse {
        var query: [URLQueryItem] = [
            URLQueryItem(name: "folder_name", value: viewName),
            URLQueryItem(name: "threaded", value: threaded ? "true" : "false"),
        ]
        if let isSeen { query.append(URLQueryItem(name: "is_seen", value: isSeen ? "true" : "false")) }
        if let since { query.append(URLQueryItem(name: "since", value: MVDateFormatting.format(since))) }
        if let before { query.append(URLQueryItem(name: "before", value: before.uuidString)) }
        if let after { query.append(URLQueryItem(name: "after", value: after.uuidString)) }
        if let around { query.append(URLQueryItem(name: "around", value: around.uuidString)) }
        query.append(URLQueryItem(name: "limit", value: String(limit)))
        return try await send(path: "/api/unified/mails", query: query)
    }
}
