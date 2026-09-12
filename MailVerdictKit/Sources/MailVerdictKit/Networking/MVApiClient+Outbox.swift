import Foundation

extension MVApiClient {

    /// Plain JSON when there are no attachments, multipart otherwise — `POST /api/outbox` accepts
    /// either, and a composer with nothing to attach has no reason to pay multipart's overhead.
    public func createOutbox(
        _ request: OutboxCreateRequest, attachments: [MVOutboxAttachmentUpload] = []
    ) async throws -> MVOutboxCreateResult {
        if attachments.isEmpty {
            return try await send(
                path: "/api/outbox", method: "POST", body: try Self.encodeBody(request)
            )
        }
        return try await sendMultipart(
            path: "/api/outbox", jsonPart: try Self.encodeBody(request), attachments: attachments
        )
    }

    public func listOutbox(accountId: UUID? = nil, status: String? = nil) async throws -> [OutboxResponse] {
        var query: [URLQueryItem] = []
        if let accountId { query.append(URLQueryItem(name: "account_id", value: accountId.uuidString)) }
        if let status { query.append(URLQueryItem(name: "status", value: status)) }
        return try await send(path: "/api/outbox", query: query)
    }

    public func listPendingSends(accountId: UUID? = nil) async throws -> [PendingSendResponse] {
        var query: [URLQueryItem] = []
        if let accountId { query.append(URLQueryItem(name: "account_id", value: accountId.uuidString)) }
        return try await send(path: "/api/outbox/pending", query: query)
    }

    public func getPendingSendAttachment(
        pendingSendId: UUID, attachmentId: UUID
    ) async throws -> (data: Data, contentType: String?, suggestedFilename: String?) {
        try await sendRaw(path: "/api/outbox/pending/\(pendingSendId)/attachments/\(attachmentId)")
    }

    public func cancelPendingSend(id: UUID) async throws {
        try await sendNoContent(path: "/api/outbox/pending/\(id)/cancel", method: "POST")
    }
}
