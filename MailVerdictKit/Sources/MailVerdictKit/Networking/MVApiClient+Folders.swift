import Foundation

extension MVApiClient {

    public func getFolderOrder(accountId: UUID) async throws -> FolderOrderResponse {
        try await send(path: "/api/accounts/\(accountId)/folder-order")
    }

    public func setFolderOrder(accountId: UUID, order: [UUID]) async throws -> FolderOrderResponse {
        try await send(
            path: "/api/accounts/\(accountId)/folder-order", method: "PUT",
            body: try Self.encodeBody(FolderOrderUpdate(order: order))
        )
    }

    public func createFolder(accountId: UUID, _ request: FolderCreateRequest) async throws -> FolderResponse {
        try await send(
            path: "/api/accounts/\(accountId)/folders", method: "POST", body: try Self.encodeBody(request)
        )
    }

    /// 409 (the actual message count disagrees with `confirmMessageCount`) reaches the caller as
    /// an ordinary `MVError.detail` naming the real count — the confirm-and-retry flow the UX
    /// design describes reads that text directly rather than this method re-deriving it.
    public func deleteFolder(folderId: UUID, confirmMessageCount: Int? = nil) async throws {
        var query: [URLQueryItem] = []
        if let confirmMessageCount {
            query.append(URLQueryItem(name: "confirm_message_count", value: String(confirmMessageCount)))
        }
        try await sendNoContent(path: "/api/folders/\(folderId)", method: "DELETE", query: query)
    }

    public func updateFolderPrefs(folderId: UUID, _ request: FolderPrefsUpdate) async throws -> FolderResponse {
        try await send(
            path: "/api/folders/\(folderId)/prefs", method: "PATCH", body: try Self.encodeBody(request)
        )
    }
}
