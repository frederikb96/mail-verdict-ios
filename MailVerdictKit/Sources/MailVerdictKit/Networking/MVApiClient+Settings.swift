import Foundation

extension MVApiClient {

    /// The server renders every category's fields generically by JSON type, and Swift's own
    /// `Dictionary` loses key order, which the generic form needs to preserve — so this hands
    /// back the raw body for an order-preserving reader to parse, rather than a typed model that
    /// would have to restate a shape the server itself does not fix.
    public func getAllSettings() async throws -> Data {
        try await sendRaw(path: "/api/settings").data
    }

    public func getSettings(category: MVSettingsCategory) async throws -> Data {
        try await sendRaw(path: "/api/settings/\(category.rawValue)").data
    }

    /// `data` is the already-encoded `{"data": {...}}` body the generic editor built — this layer
    /// never interprets a setting's fields, only carries them.
    public func updateSettings(category: MVSettingsCategory, data: Data) async throws -> Data {
        let (body, response) = try await rawSend(
            path: "/api/settings/\(category.rawValue)", method: "PUT", query: [], body: data,
            contentType: "application/json"
        )
        try checkStatus(response: response, data: body)
        return body
    }

    public func importSettings(data: Data) async throws -> Data {
        let (body, response) = try await rawSend(
            path: "/api/settings/import", method: "POST", query: [], body: data,
            contentType: "application/json"
        )
        try checkStatus(response: response, data: body)
        return body
    }
}
