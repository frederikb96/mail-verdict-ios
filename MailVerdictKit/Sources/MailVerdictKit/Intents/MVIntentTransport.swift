import Foundation

#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif

/// A message as the ledger checks it before sending again an intent that may already have landed.
public struct MVMessageState: Sendable, Equatable {
    public let folderId: UUID
    /// `nil` when the lookup did not read them.
    public let isSeen: Bool?
    public let isFlagged: Bool?

    public init(folderId: UUID, isSeen: Bool? = nil, isFlagged: Bool? = nil) {
        self.folderId = folderId
        self.isSeen = isSeen
        self.isFlagged = isFlagged
    }
}

/// The requests an intent is delivered with. `MVApiClient` is the one real implementation.
public protocol MVIntentTransport: Sendable {
    func deliverMessageAction(
        messageId: UUID, action: MVMessageAction, targetFolderId: UUID?, expectedFolderId: UUID?, idempotencyKey: UUID,
        timeout: TimeInterval
    ) async throws -> MessageActionResponse
    func deliverBulkAction(
        accountId: UUID, request: BulkActionRequest, timeout: TimeInterval
    ) async throws -> BulkActionResponse
    func fetchConversation(messageId: UUID, timeout: TimeInterval) async throws -> ThreadResponse
    /// `nil` when the message no longer exists. `includeFlags` reads read and star state too,
    /// which costs the whole message rather than its location.
    func fetchMessageState(messageId: UUID, includeFlags: Bool, timeout: TimeInterval) async throws -> MVMessageState?
    func fetchFolders(accountId: UUID, timeout: TimeInterval) async throws -> [FolderResponse]
}

extension MVApiClient: MVIntentTransport {
    public func deliverMessageAction(
        messageId: UUID, action: MVMessageAction, targetFolderId: UUID?, expectedFolderId: UUID?, idempotencyKey: UUID,
        timeout: TimeInterval
    ) async throws -> MessageActionResponse {
        try await performMessageAction(
            messageId: messageId, action: action, targetFolderId: targetFolderId, idempotencyKey: idempotencyKey,
            expectedFolderId: expectedFolderId, timeout: timeout)
    }

    public func deliverBulkAction(
        accountId: UUID, request: BulkActionRequest, timeout: TimeInterval
    ) async throws -> BulkActionResponse {
        try await bulkAction(accountId: accountId, request: request, timeout: timeout)
    }

    public func fetchConversation(messageId: UUID, timeout: TimeInterval) async throws -> ThreadResponse {
        try await getThread(messageId: messageId, loadImages: false, timeout: timeout)
    }

    public func fetchFolders(accountId: UUID, timeout: TimeInterval) async throws -> [FolderResponse] {
        try await listFolders(accountId: accountId, timeout: timeout)
    }

    public func fetchMessageState(
        messageId: UUID, includeFlags: Bool, timeout: TimeInterval
    ) async throws -> MVMessageState? {
        do {
            if includeFlags {
                let message = try await getMessage(id: messageId, loadImages: false, timeout: timeout)
                return MVMessageState(folderId: message.folderId, isSeen: message.isSeen, isFlagged: message.isFlagged)
            }
            let location = try await locateMessage(id: messageId, timeout: timeout)
            return MVMessageState(folderId: location.folderId)
        } catch let error as MVError {
            switch error {
            case .detail(_, 404), .http(404, _): return nil
            default: throw error
            }
        }
    }
}

/// What a delivery attempt means for the intent.
enum MVIntentDelivery: Equatable {
    /// `filed`: where the server says it put each message.
    case delivered(affectedCount: Int?, sources: [BulkActionSource], filed: [UUID: UUID] = [:])
    /// A guarded action whose messages had all moved on: nothing written, nothing to retry.
    case notApplied
    /// 404: the message is gone. Nothing left to do or to show.
    case gone
    /// Worth trying again: no response, a timeout, a rate limit or a server error. `mayHaveLanded`
    /// when the request could have been applied without its answer coming back.
    case retry(String, mayHaveLanded: Bool)
    /// The credential or the login proxy refused it: nothing was applied, and nothing is sent
    /// for a while.
    case hold(String)
    /// 503: the server is still applying an earlier attempt, or is not taking requests at all.
    /// Nothing new was applied; asked again shortly, without counting as an attempt.
    case busy(String)
    /// The server refused the request itself; sending it again would be refused again.
    case refused(String)

    static func classify(_ error: Error) -> MVIntentDelivery {
        if let error = error as? URLError {
            return .retry(error.localizedDescription, mayHaveLanded: !neverLeft.contains(error.code))
        }
        guard let error = error as? MVError else {
            return .retry("\(error)", mayHaveLanded: true)
        }
        switch error {
        case .detail(_, let status), .http(let status, _):
            if status == 404 { return .gone }
            if status == 401 || status == 403 { return .hold(error.userMessage) }
            if status == 408 || status == 425 || status == 429 {
                return .retry(error.userMessage, mayHaveLanded: false)
            }
            if status == 503 { return .busy(error.userMessage) }
            if status >= 500 { return .retry(error.userMessage, mayHaveLanded: true) }
            return .refused(error.userMessage)
        case .transport:
            return .retry(error.userMessage, mayHaveLanded: true)
        case .decoding:
            // The status check passed before the body was read: the server accepted the request.
            return .delivered(affectedCount: nil, sources: [])
        case .proxyRequiresBrowserLogin:
            return .hold(error.userMessage)
        }
    }

    /// Failures that happen before a request is on the wire.
    private static let neverLeft: Set<URLError.Code> = [
        .notConnectedToInternet, .cannotFindHost, .cannotConnectToHost, .dnsLookupFailed,
    ]
}
