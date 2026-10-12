import XCTest
@testable import MailVerdictKit

final class SearchSupportResultsStateTests: XCTestCase {

    func testSelectAFolderWinsEvenWithAShortQuery() {
        XCTAssertEqual(
            SearchSupport.resultsState(
                query: "a", folderIds: [], isLoading: false, errorMessage: nil, resultCount: 0, hasSearched: false
            ), .selectAFolder
        )
    }

    func testEnterQueryBelowTwoCharacters() {
        XCTAssertEqual(
            SearchSupport.resultsState(
                query: "a", folderIds: nil, isLoading: false, errorMessage: nil, resultCount: 0, hasSearched: false
            ), .enterQuery
        )
    }

    func testLoadingBeforeTheFirstSearchCompletes() {
        XCTAssertEqual(
            SearchSupport.resultsState(
                query: "hello", folderIds: nil, isLoading: true, errorMessage: nil, resultCount: 0,
                hasSearched: false
            ), .loading
        )
    }

    func testErrorTakesPriorityOverNoResults() {
        XCTAssertEqual(
            SearchSupport.resultsState(
                query: "hello", folderIds: nil, isLoading: false, errorMessage: "boom", resultCount: 0,
                hasSearched: true
            ), .error("boom")
        )
    }

    func testNoResultsOnlyAfterASearchActuallyRan() {
        XCTAssertEqual(
            SearchSupport.resultsState(
                query: "hello", folderIds: nil, isLoading: false, errorMessage: nil, resultCount: 0,
                hasSearched: true
            ), .noResults
        )
        XCTAssertEqual(
            SearchSupport.resultsState(
                query: "hello", folderIds: nil, isLoading: false, errorMessage: nil, resultCount: 0,
                hasSearched: false
            ), .results
        )
    }

    func testResultsWhenThereAreSome() {
        XCTAssertEqual(
            SearchSupport.resultsState(
                query: "hello", folderIds: nil, isLoading: false, errorMessage: nil, resultCount: 3,
                hasSearched: true
            ), .results
        )
    }
}

final class SearchSupportFolderIdsAfterAccountChangeTests: XCTestCase {

    func testNilStaysNil() {
        XCTAssertNil(SearchSupport.folderIdsAfterAccountChange(currentFolderIds: nil, newAccountFolderIds: []))
    }

    func testExplicitEmptySelectionStaysEmpty() {
        XCTAssertEqual(
            SearchSupport.folderIdsAfterAccountChange(currentFolderIds: [], newAccountFolderIds: []), []
        )
    }

    func testResetsToNilWhenNoneOfTheSelectedFoldersBelongToTheNewAccount() {
        let selected = UUID()
        XCTAssertNil(
            SearchSupport.folderIdsAfterAccountChange(
                currentFolderIds: [selected], newAccountFolderIds: [UUID()]
            )
        )
    }

    func testKeepsOnlyTheFoldersThatStillBelongToTheNewAccount() {
        let keep = UUID()
        let drop = UUID()
        let result = SearchSupport.folderIdsAfterAccountChange(
            currentFolderIds: [keep, drop], newAccountFolderIds: [keep]
        )
        XCTAssertEqual(result, [keep])
    }
}

final class SearchSupportSemanticPendingTests: XCTestCase {

    func testAnEmptyFullTextAnswerWhileTheSemanticOneIsPendingIsNotNoResults() {
        XCTAssertEqual(
            SearchSupport.resultsState(
                query: "hello", folderIds: nil, isLoading: true, errorMessage: nil, resultCount: 0,
                hasSearched: true, semanticState: .pending
            ), .searchingByMeaning
        )
    }

    func testAnEmptySettledAnswerIsNoResults() {
        XCTAssertEqual(
            SearchSupport.resultsState(
                query: "hello", folderIds: nil, isLoading: false, errorMessage: nil, resultCount: 0,
                hasSearched: true, semanticState: .settled
            ), .noResults
        )
    }

    func testAnUnavailableSemanticAnswerWithNoHitsIsNoResults() {
        XCTAssertEqual(
            SearchSupport.resultsState(
                query: "hello", folderIds: nil, isLoading: false, errorMessage: nil, resultCount: 0,
                hasSearched: true, semanticState: .unavailable
            ), .noResults
        )
    }
}

final class SearchSupportRowsTests: XCTestCase {

    private func result(tier: Int?) -> MVSearchHit {
        MVSearchHit(
            result: SearchResult(
                id: UUID(), accountId: UUID(), folderId: UUID(), threadId: UUID(), subject: nil, fromAddr: nil,
                toAddrs: nil, receivedAt: nil, snippet: nil, mirroredAt: Date(timeIntervalSince1970: 0)),
            tier: tier)
    }

    func testTheDividerSitsOnceBeforeTheFirstLessLikelyHit() {
        let results = [1, 1, 2, 2].map { result(tier: $0) }
        let rows = SearchSupport.rows(for: results)
        XCTAssertEqual(rows.count, 5)
        XCTAssertEqual(rows[2], .lessLikelyDivider)
        XCTAssertEqual(rows.filter { $0 == .lessLikelyDivider }.count, 1)
        XCTAssertEqual(rows[3], .hit(results[2]))
    }

    func testNoDividerWithoutALessLikelyHit() {
        let rows = SearchSupport.rows(for: [result(tier: 1), result(tier: 1)])
        XCTAssertFalse(rows.contains(.lessLikelyDivider))
    }

    func testFullTextHitsCarryNoTierAndGetNoDivider() {
        let rows = SearchSupport.rows(for: [result(tier: nil), result(tier: nil)])
        XCTAssertEqual(rows.count, 2)
        XCTAssertFalse(rows.contains(.lessLikelyDivider))
    }

    func testADividerStillLeadsWhenEveryHitIsLessLikely() {
        let rows = SearchSupport.rows(for: [result(tier: 2)])
        XCTAssertEqual(rows.first, .lessLikelyDivider)
    }
}
