import Foundation

extension MVApiClient {

    public func listIdentities(accountId: UUID? = nil) async throws -> [IdentityResponse] {
        var query: [URLQueryItem] = []
        if let accountId { query.append(URLQueryItem(name: "account_id", value: accountId.uuidString)) }
        return try await send(path: "/api/identities", query: query)
    }

    public func createIdentity(_ request: IdentityCreate) async throws -> IdentityResponse {
        try await send(path: "/api/identities", method: "POST", body: try Self.encodeBody(request))
    }

    public func updateIdentity(id: UUID, _ request: IdentityUpdate) async throws -> IdentityResponse {
        try await send(path: "/api/identities/\(id)", method: "PATCH", body: try Self.encodeBody(request))
    }

    public func deleteIdentity(id: UUID) async throws {
        try await sendNoContent(path: "/api/identities/\(id)", method: "DELETE")
    }
}
