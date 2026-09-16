import Foundation

#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif

/// The requests an intent is delivered with. `MVApiClient` is the one real implementation.
public protocol MVIntentTransport: Sendable {
    func deliverMessageAction(
        messageId: UUID, action: MVMessageAction, targetFolderId: UUID?, idempotencyKey: UUID, timeout: TimeInterval
    ) async throws
    func deliverBulkAction(
        accountId: UUID, request: BulkActionRequest, timeout: TimeInterval
    ) async throws -> BulkActionResponse
    func fetchThread(messageId: UUID) async throws -> ThreadResponse
}

extension MVApiClient: MVIntentTransport {
    public func deliverMessageAction(
        messageId: UUID, action: MVMessageAction, targetFolderId: UUID?, idempotencyKey: UUID, timeout: TimeInterval
    ) async throws {
        _ = try await performMessageAction(
            messageId: messageId, action: action, targetFolderId: targetFolderId, idempotencyKey: idempotencyKey,
            timeout: timeout)
    }

    public func deliverBulkAction(
        accountId: UUID, request: BulkActionRequest, timeout: TimeInterval
    ) async throws -> BulkActionResponse {
        try await bulkAction(accountId: accountId, request: request, timeout: timeout)
    }
}

/// What a delivery attempt means for the intent.
enum MVIntentDelivery: Equatable {
    case delivered(affectedCount: Int?, sources: [BulkActionSource])
    /// 404: the message is gone. Nothing left to do or to show.
    case gone
    /// Worth trying again: no response, a timeout, a rate limit or a server error.
    case retry(String)
    /// The server refused the request itself; sending it again would be refused again.
    case refused(String)

    static func classify(_ error: Error) -> MVIntentDelivery {
        guard let error = error as? MVError else {
            return .retry((error as? URLError).map { $0.localizedDescription } ?? "\(error)")
        }
        switch error {
        case .detail(_, let status), .http(let status, _):
            if status == 404 { return .gone }
            if status == 408 || status == 425 || status == 429 || status >= 500 { return .retry(error.userMessage) }
            return .refused(error.userMessage)
        case .transport:
            return .retry(error.userMessage)
        case .decoding:
            // The status check passed before the body was read: the server accepted the request.
            return .delivered(affectedCount: nil, sources: [])
        case .proxyRequiresBrowserLogin:
            return .refused(error.userMessage)
        }
    }
}
