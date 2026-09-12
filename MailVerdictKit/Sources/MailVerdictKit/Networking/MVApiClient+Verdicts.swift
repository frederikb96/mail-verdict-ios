import Foundation

extension MVApiClient {

    public func submitFeedback(messageId: UUID, accountId: UUID, isSpam: Bool) async throws -> FeedbackResponse {
        try await send(
            path: "/api/mails/\(messageId)/feedback", method: "POST",
            query: [URLQueryItem(name: "account_id", value: accountId.uuidString)],
            body: try Self.encodeBody(FeedbackRequest(isSpam: isSpam))
        )
    }

    public func listSpamReview(before: UUID? = nil, limit: Int = 50) async throws -> SpamReviewListResponse {
        var query: [URLQueryItem] = [URLQueryItem(name: "limit", value: String(limit))]
        if let before { query.append(URLQueryItem(name: "before", value: before.uuidString)) }
        return try await send(path: "/api/verdicts/spam-review", query: query)
    }
}
