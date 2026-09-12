import Foundation

extension MVApiClient {

    public func searchDateBounds(
        accountId: UUID?, folderIds: [UUID]?
    ) async throws -> SearchDateBoundsResponse {
        var query: [URLQueryItem] = []
        if let accountId { query.append(URLQueryItem(name: "account_id", value: accountId.uuidString)) }
        folderIds?.forEach { query.append(URLQueryItem(name: "folder_ids", value: $0.uuidString)) }
        return try await send(path: "/api/search/date-bounds", query: query)
    }

    public func search(
        query q: String, accountId: UUID?, folderIds: [UUID]?, fields: [MVSearchField]?,
        sort: MVSearchSort = .relevance, receivedAfter: Date? = nil, receivedBefore: Date? = nil,
        isSeen: Bool? = nil, before: UUID? = nil, limit: Int = 50
    ) async throws -> SearchResponse {
        var query: [URLQueryItem] = [
            URLQueryItem(name: "q", value: q), URLQueryItem(name: "sort", value: sort.rawValue),
            URLQueryItem(name: "limit", value: String(limit)),
        ]
        if let accountId { query.append(URLQueryItem(name: "account_id", value: accountId.uuidString)) }
        folderIds?.forEach { query.append(URLQueryItem(name: "folder_ids", value: $0.uuidString)) }
        fields?.forEach { query.append(URLQueryItem(name: "fields", value: $0.rawValue)) }
        if let receivedAfter {
            query.append(URLQueryItem(name: "received_after", value: MVDateFormatting.format(receivedAfter)))
        }
        if let receivedBefore {
            query.append(URLQueryItem(name: "received_before", value: MVDateFormatting.format(receivedBefore)))
        }
        if let isSeen { query.append(URLQueryItem(name: "is_seen", value: isSeen ? "true" : "false")) }
        if let before { query.append(URLQueryItem(name: "before", value: before.uuidString)) }
        return try await send(path: "/api/search", query: query)
    }

    public func semanticSearch(
        query q: String, accountId: UUID?, folderIds: [UUID]?,
        strictness: MVSemanticStrictness? = nil, sort: MVSemanticSort = .relevance,
        receivedAfter: Date? = nil, receivedBefore: Date? = nil
    ) async throws -> SemanticSearchResponse {
        var query: [URLQueryItem] = [
            URLQueryItem(name: "q", value: q), URLQueryItem(name: "sort", value: sort.rawValue),
        ]
        if let accountId { query.append(URLQueryItem(name: "account_id", value: accountId.uuidString)) }
        folderIds?.forEach { query.append(URLQueryItem(name: "folder_ids", value: $0.uuidString)) }
        if let strictness { query.append(URLQueryItem(name: "strictness", value: strictness.rawValue)) }
        if let receivedAfter {
            query.append(URLQueryItem(name: "received_after", value: MVDateFormatting.format(receivedAfter)))
        }
        if let receivedBefore {
            query.append(URLQueryItem(name: "received_before", value: MVDateFormatting.format(receivedBefore)))
        }
        return try await send(path: "/api/embeddings/search", query: query)
    }
}
