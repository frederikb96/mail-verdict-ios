import Foundation

/// What the results area shows instead of a result list, kept as a single pure function so the
/// screen renders from one decision rather than re-deriving it from several independent
/// conditions that could disagree.
public enum MVSearchResultsState: Sendable, Equatable {
    case enterQuery
    case selectAFolder
    case loading
    case error(String)
    case noResults
    case results
}

public enum SearchSupport {

    /// `folderIds == []` means "search nothing" — distinct from `nil`, "every folder" — checked
    /// before the query-length gate, since an empty folder scope is wrong regardless of how long
    /// the query is.
    public static func resultsState(
        query: String, folderIds: [UUID]?, isLoading: Bool, errorMessage: String?, resultCount: Int,
        hasSearched: Bool
    ) -> MVSearchResultsState {
        if folderIds?.isEmpty == true { return .selectAFolder }
        if query.count < 2 { return .enterQuery }
        if isLoading && !hasSearched { return .loading }
        if let errorMessage { return .error(errorMessage) }
        if hasSearched && resultCount == 0 { return .noResults }
        return .results
    }

    /// Semantic search's 503 (`embeddings.py` raises it with the provider's own exception text)
    /// reads as this fixed sentence rather than whatever that exception happened to say, which a
    /// dynamic `str(exc)` would make unpredictable from the client's side.
    public static func errorMessage(mode: SearchContext.Mode, statusCode: Int?, serverDetail: String) -> String {
        if mode == .semantic, statusCode == 503 {
            return "Semantic search is unavailable — no AI provider is configured for it."
        }
        return serverDetail
    }

    /// Changing the account scope drops a folder selection that no longer belongs to it, resetting
    /// to `nil` ("every folder") rather than leaving a now-meaningless id list behind — distinct
    /// from "Deselect All" explicitly setting `[]` ("search nothing").
    public static func folderIdsAfterAccountChange(
        currentFolderIds: [UUID]?, newAccountFolderIds: Set<UUID>
    ) -> [UUID]? {
        guard let currentFolderIds, !currentFolderIds.isEmpty else { return currentFolderIds }
        let stillValid = currentFolderIds.filter { newAccountFolderIds.contains($0) }
        return stillValid.isEmpty ? nil : stillValid
    }
}
