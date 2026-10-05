import Foundation

extension MVApiClient {

    /// The assistant makes a few model calls and the server gives up after 150 s, so the request is
    /// allowed a little longer than that rather than the default.
    private static let assistantTimeout: TimeInterval = 160

    public func proposeRule(messageId: UUID, prompt: String) async throws -> RuleAssistantResponse {
        try await send(
            path: "/api/pipeline/assistant", method: "POST",
            body: try Self.encodeBody(RuleAssistantRequest(messageId: messageId, prompt: prompt)),
            timeout: Self.assistantTimeout)
    }

    /// Fails with a `409` when `request.baseRevision` is no longer the current revision. The route
    /// answers with the written document, which the caller has no use for.
    public func replacePipeline(_ request: PipelineWriteRequest) async throws {
        try await sendNoContent(path: "/api/pipeline", method: "PUT", body: try Self.encodeBody(request))
    }
}
