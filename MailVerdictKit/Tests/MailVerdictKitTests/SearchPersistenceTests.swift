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
        let context = SearchContext(mode: .semantic, query: "invoices", strictness: .strict)
        persistence.saveContext(context)
        XCTAssertEqual(persistence.loadContext(), context)
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
