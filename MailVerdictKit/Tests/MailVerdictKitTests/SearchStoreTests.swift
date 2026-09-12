import XCTest
@testable import MailVerdictKit

@MainActor
final class SearchStoreTests: XCTestCase {

    override func tearDown() {
        MVStubURLProtocol.reset()
        super.tearDown()
    }

    private func makeStore(defaults: UserDefaults, initialQuery: String? = nil) -> SearchStore {
        let factory = try! MVRequestFactory(baseURL: "https://stub.example.com", authProvider: { .none })
        let client = MVApiClient(requestFactory: factory, urlSession: MVStubURLProtocol.makeSession())
        return SearchStore(
            apiClient: client, persistence: SearchPersistence(defaults: defaults), initialQuery: initialQuery
        )
    }

    private func makeDefaults() -> UserDefaults {
        let suite = "SearchStoreTests.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        return defaults
    }

    func testAQueryUnderTwoCharactersNeverHitsTheNetwork() async {
        let store = makeStore(defaults: makeDefaults())
        // No stub registered — a network call here would fail with `.badServerResponse`.
        store.queryChanged("a")
        await store.runSearch()
        XCTAssertEqual(store.results, [])
        XCTAssertFalse(store.hasSearched)
    }

    func testAnEmptyFolderScopeNeverHitsTheNetworkEvenWithAValidQuery() async {
        let store = makeStore(defaults: makeDefaults())
        await store.updateContext(SearchContext(mode: .text, query: "invoices", folderIds: []))
        XCTAssertEqual(store.results, [])
        XCTAssertEqual(store.resultsState, .selectAFolder)
    }

    func testASuccessfulTextSearchPopulatesResultsAndReaderTitle() async throws {
        let messageId = UUID(), accountId = UUID(), folderId = UUID(), threadId = UUID()
        let json = """
            {"results":[{"id":"\(messageId)","account_id":"\(accountId)","folder_id":"\(folderId)",
            "thread_id":"\(threadId)","subject":"Invoice","from_addr":"a@b.com","to_addrs":null,
            "received_at":null,"snippet":"**Invoice** attached","mirrored_at":"2026-01-01T00:00:00+00:00",
            "has_attachments":false}],"has_more":false,"next_cursor":null,"query":"invoice","total":1}
            """
        MVStubURLProtocol.stub = .init(statusCode: 200, headers: [:], body: Data(json.utf8))

        let store = makeStore(defaults: makeDefaults())
        await store.updateContext(SearchContext(mode: .text, query: "invoice"))

        XCTAssertEqual(store.results.map(\.id), [messageId])
        XCTAssertTrue(store.hasSearched)
        XCTAssertEqual(store.readerTitle, "1 Results")
        XCTAssertEqual(store.resultsState, .results)
    }

    func testASemantic503BecomesTheFixedUnavailableMessage() async throws {
        MVStubURLProtocol.stub = .init(
            statusCode: 503, headers: [:], body: Data(#"{"detail":"no embeddings provider configured"}"#.utf8))

        let store = makeStore(defaults: makeDefaults())
        await store.updateContext(SearchContext(mode: .semantic, query: "invoice"))

        XCTAssertEqual(
            store.resultsState, .error("Semantic search is unavailable — no AI provider is configured for it."))
    }

    func testAnInitialQueryFromTheRouteOverridesAnyPersistedOne() async {
        let defaults = makeDefaults()
        SearchPersistence(defaults: defaults).saveContext(SearchContext(mode: .text, query: "old"))
        let store = makeStore(defaults: defaults, initialQuery: "new")
        XCTAssertEqual(store.context.query, "new")
    }

    func testReaderListSourceNeighboursWalkResultOrder() async throws {
        let a = UUID(), b = UUID(), c = UUID()
        let json = """
            {"results":[
              {"id":"\(a)","account_id":"\(UUID())","folder_id":"\(UUID())","thread_id":"\(UUID())",
               "subject":"A","from_addr":null,"to_addrs":null,"received_at":null,"snippet":null,
               "mirrored_at":"2026-01-01T00:00:00+00:00","has_attachments":false},
              {"id":"\(b)","account_id":"\(UUID())","folder_id":"\(UUID())","thread_id":"\(UUID())",
               "subject":"B","from_addr":null,"to_addrs":null,"received_at":null,"snippet":null,
               "mirrored_at":"2026-01-01T00:00:00+00:00","has_attachments":false},
              {"id":"\(c)","account_id":"\(UUID())","folder_id":"\(UUID())","thread_id":"\(UUID())",
               "subject":"C","from_addr":null,"to_addrs":null,"received_at":null,"snippet":null,
               "mirrored_at":"2026-01-01T00:00:00+00:00","has_attachments":false}
            ],"has_more":false,"next_cursor":null,"query":"xx","total":3}
            """
        MVStubURLProtocol.stub = .init(statusCode: 200, headers: [:], body: Data(json.utf8))

        let store = makeStore(defaults: makeDefaults())
        await store.updateContext(SearchContext(mode: .text, query: "xx"))

        XCTAssertEqual(store.rowIds, [a, b, c])
        XCTAssertEqual(store.neighbours(of: b).older, c)
        XCTAssertEqual(store.neighbours(of: b).newer, a)
        XCTAssertEqual(store.neighbours(of: a).newer, nil)
        XCTAssertEqual(store.neighbours(of: c).older, nil)
        XCTAssertFalse(store.hasNewer)
    }
}
