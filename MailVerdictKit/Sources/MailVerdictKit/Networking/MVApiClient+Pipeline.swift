import Foundation

extension MVApiClient {

    /// The assistant makes up to a few model calls and the server gives up after 55 s, so the
    /// request is allowed a little longer than that rather than the default.
    private static let assistantTimeout: TimeInterval = 60

    public func proposeRule(messageId: UUID, prompt: String) async throws -> RuleAssistantResponse {
        try await send(
            path: "/api/pipeline/assistant", method: "POST",
            body: try Self.encodeBody(RuleAssistantRequest(messageId: messageId, prompt: prompt)),
            timeout: Self.assistantTimeout)
    }

    /// Fails with a `409` when `request.baseRevision` is no longer the current revision.
    public func createStage(_ request: StageCreateRequest) async throws {
        try await sendNoContentBody(path: "/api/pipeline/stages", method: "POST", body: request)
    }

    public func updateStage(id: String, _ request: StageUpdateRequest) async throws {
        try await sendNoContentBody(path: "/api/pipeline/stages/\(id)", method: "PATCH", body: request)
    }

    /// The stage routes answer with the updated document, which the caller has no use for.
    private func sendNoContentBody<Body: Encodable>(path: String, method: String, body: Body) async throws {
        try await sendNoContent(path: path, method: method, body: try Self.encodeBody(body))
    }
}
