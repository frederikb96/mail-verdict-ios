import Foundation

extension MVApiClient {

    public func listImageExceptions(accountId: UUID) async throws -> [ImageExceptionResponse] {
        try await send(path: "/api/accounts/\(accountId)/image-exceptions")
    }

    public func createImageException(
        accountId: UUID, _ request: ImageExceptionCreate
    ) async throws -> ImageExceptionResponse {
        try await send(
            path: "/api/accounts/\(accountId)/image-exceptions", method: "POST",
            body: try Self.encodeBody(request)
        )
    }

    public func deleteImageException(accountId: UUID, exceptionId: UUID) async throws {
        try await sendNoContent(
            path: "/api/accounts/\(accountId)/image-exceptions/\(exceptionId)", method: "DELETE"
        )
    }
}
