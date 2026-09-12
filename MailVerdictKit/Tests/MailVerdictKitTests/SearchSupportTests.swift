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

final class SearchSupportErrorMessageTests: XCTestCase {

    func testSemantic503BecomesTheFixedSentence() {
        XCTAssertEqual(
            SearchSupport.errorMessage(mode: .semantic, statusCode: 503, serverDetail: "connection refused"),
            "Semantic search is unavailable — no AI provider is configured for it."
        )
    }

    func testTextMode503PassesTheServerDetailThrough() {
        XCTAssertEqual(
            SearchSupport.errorMessage(mode: .text, statusCode: 503, serverDetail: "maintenance"), "maintenance"
        )
    }

    func testSemanticNon503PassesTheServerDetailThrough() {
        XCTAssertEqual(
            SearchSupport.errorMessage(mode: .semantic, statusCode: 500, serverDetail: "internal error"),
            "internal error"
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
