import Foundation

/// What the results area shows instead of a result list, kept as a single pure function so the
/// screen renders from one decision rather than re-deriving it from several independent
/// conditions that could disagree.
public enum MVSearchResultsState: Sendable, Equatable {
    case enterQuery
    case selectAFolder
    case loading
    /// Semantic mode, the full-text query found nothing and the meaning-based answer is pending.
    case searchingByMeaning
    case error(String)
    case noResults
    case results
}

/// A search hit as the results list sees it: the message plus, for semantic search, the server's
/// tier. Full-text hits carry no tier.
public struct MVSearchHit: Equatable, Sendable, Identifiable {
    public let result: SearchResult
    public let tier: Int?

    public var id: UUID { result.id }

    public init(result: SearchResult, tier: Int? = nil) {
        self.result = result
        self.tier = tier
    }
}

public enum MVSemanticState: Sendable, Equatable {
    /// Nothing to add to the list on screen.
    case settled
    /// The list is the full-text answer, shown until the semantic one replaces it.
    case pending
    /// The server could not answer by meaning; the list is the full-text one.
    case unavailable
}

/// One line of the results list: a hit, or the divider that precedes the first less likely one.
public enum MVSearchRow: Equatable, Sendable, Identifiable {
    case hit(MVSearchHit)
    case lessLikelyDivider

    public var id: String {
        switch self {
        case .hit(let hit): return "result:\(hit.id)"
        case .lessLikelyDivider: return "divider:less-likely"
        }
    }
}

public enum SearchSupport {

    /// The server orders a semantic result tier first, newest first within a tier; the client only
    /// marks where tier 2 begins. Full-text hits carry no tier and never get a divider.
    public static func rows(for hits: [MVSearchHit]) -> [MVSearchRow] {
        var rows: [MVSearchRow] = []
        var dividerPlaced = false
        for hit in hits {
            if !dividerPlaced, (hit.tier ?? 0) >= 2 {
                rows.append(.lessLikelyDivider)
                dividerPlaced = true
            }
            rows.append(.hit(hit))
        }
        return rows
    }

    /// `folderIds == []` means "search nothing" — distinct from `nil`, "every folder" — checked
    /// before the query-length gate, since an empty folder scope is wrong regardless of how long
    /// the query is.
    public static func resultsState(
        query: String, folderIds: [UUID]?, isLoading: Bool, errorMessage: String?, resultCount: Int,
        hasSearched: Bool, semanticState: MVSemanticState = .settled
    ) -> MVSearchResultsState {
        if folderIds?.isEmpty == true { return .selectAFolder }
        if query.count < 2 { return .enterQuery }
        if isLoading && !hasSearched { return .loading }
        if let errorMessage { return .error(errorMessage) }
        if semanticState == .pending && resultCount == 0 { return .searchingByMeaning }
        if hasSearched && resultCount == 0 { return .noResults }
        return .results
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
