import Foundation

extension MVApiClient {

    /// Composer autocomplete — one row per email address, never the full contact management
    /// shape (out of scope; see Models/Contact.swift's header).
    public func searchContacts(query: String) async throws -> [ContactSearchHitOut] {
        try await send(path: "/api/contacts/search", query: [URLQueryItem(name: "q", value: query)])
    }

    public func getContactPhotoIndex(accountId: UUID? = nil) async throws -> ContactPhotoIndexResponse {
        var query: [URLQueryItem] = []
        if let accountId { query.append(URLQueryItem(name: "account_id", value: accountId.uuidString)) }
        return try await send(path: "/api/contacts/photo-index", query: query)
    }

    public func getContactPhoto(contactId: UUID) async throws -> (data: Data, contentType: String?) {
        let result = try await sendRaw(path: "/api/contacts/\(contactId)/photo")
        return (result.data, result.contentType)
    }
}
