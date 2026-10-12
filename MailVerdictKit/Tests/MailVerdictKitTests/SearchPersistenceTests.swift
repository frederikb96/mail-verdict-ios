import XCTest
@testable import MailVerdictKit

final class SearchPersistenceTests: XCTestCase {

    private func makeDefaults() -> UserDefaults {
        let suite = "SearchPersistenceTests.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        return defaults
    }

    func testContextRoundTrips() {
        let persistence = SearchPersistence(defaults: makeDefaults())
        XCTAssertNil(persistence.loadContext())
        let context = SearchContext(mode: .semantic, query: "invoices", timeWindow: .preset(.last7Days))
        persistence.saveContext(context)
        XCTAssertEqual(persistence.loadContext(), context)
    }

    func testAContextSavedBeforeTheTimeWindowExistedStillLoads() throws {
        let defaults = makeDefaults()
        let legacy =
            #"{"mode":"semantic","query":"invoices","strictness":"strict","sort":"chronological","receivedAfter":"2026-01-01T00:00:00Z"}"#
        defaults.set(Data(legacy.utf8), forKey: "mv.search.context")
        let loaded = try XCTUnwrap(SearchPersistence(defaults: defaults).loadContext())
        XCTAssertEqual(loaded.query, "invoices")
        XCTAssertNil(loaded.timeWindow)
    }

    func testAnchorRoundTripsUnderTheSameContext() {
        let persistence = SearchPersistence(defaults: makeDefaults())
        let context = SearchContext(mode: .text, query: "hello")
        XCTAssertNil(persistence.loadAnchor(for: context))
        persistence.saveAnchor("result:\(UUID())", for: context)
        XCTAssertNotNil(persistence.loadAnchor(for: context))
    }

    func testAnchorIsDiscardedUnderADifferentContext() {
        let persistence = SearchPersistence(defaults: makeDefaults())
        let original = SearchContext(mode: .text, query: "hello")
        let changed = SearchContext(mode: .text, query: "goodbye")
        persistence.saveAnchor("result:\(UUID())", for: original)
        XCTAssertNil(persistence.loadAnchor(for: changed))
    }

    func testSavingANilAnchorClearsIt() {
        let persistence = SearchPersistence(defaults: makeDefaults())
        let context = SearchContext(mode: .text, query: "hello")
        persistence.saveAnchor("result:\(UUID())", for: context)
        persistence.saveAnchor(nil, for: context)
        XCTAssertNil(persistence.loadAnchor(for: context))
    }
}
