import Foundation

extension MVApiClient {

    public func listUnifiedFolders() async throws -> [UnifiedFolderResponse] {
        try await send(path: "/api/unified/folders")
    }

    public func createUnifiedView(_ request: UnifiedViewCreate) async throws -> UnifiedViewResponse {
        try await send(path: "/api/unified/views", method: "POST", body: try Self.encodeBody(request))
    }

    public func updateUnifiedView(id: UUID, _ request: UnifiedViewUpdate) async throws -> UnifiedViewResponse {
        try await send(
            path: "/api/unified/views/\(id)", method: "PATCH", body: try Self.encodeBody(request)
        )
    }

    public func deleteUnifiedView(id: UUID) async throws {
        try await sendNoContent(path: "/api/unified/views/\(id)", method: "DELETE")
    }

    public func getUnifiedFolderOrder() async throws -> UnifiedFolderOrderResponse {
        try await send(path: "/api/unified/folder-order")
    }

    public func setUnifiedFolderOrder(order: [String]) async throws -> UnifiedFolderOrderResponse {
        try await send(
            path: "/api/unified/folder-order", method: "PUT",
            body: try Self.encodeBody(UnifiedFolderOrderUpdate(order: order))
        )
    }
}
