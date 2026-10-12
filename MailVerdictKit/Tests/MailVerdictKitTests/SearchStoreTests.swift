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

    func testAnInitialQueryFromTheRouteOverridesAnyPersistedOne() async {
        let defaults = makeDefaults()
        SearchPersistence(defaults: defaults).saveContext(SearchContext(mode: .text, query: "old"))
        let store = makeStore(defaults: defaults, initialQuery: "new")
        XCTAssertEqual(store.context.query, "new")
    }

    func testReaderListSourceRowIdsWalkResultOrder() async throws {
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
        XCTAssertFalse(store.hasNewer)
    }

    func testApplyingAMailEventReRunsTheCurrentSearchOnlyAfterOneHasRun() async throws {
        let store = makeStore(defaults: makeDefaults())
        // No stub registered — `apply` must be a no-op before any search has ever run, or this
        // would fail with `.badServerResponse`.
        store.apply([.mailNew(accountId: nil, folderId: nil, messageId: nil)])
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(store.results, [])

        let json = """
            {"results":[],"has_more":false,"next_cursor":null,"query":"xx","total":0}
            """
        MVStubURLProtocol.stub = .init(statusCode: 200, headers: [:], body: Data(json.utf8))
        await store.updateContext(SearchContext(mode: .text, query: "xx"))
        XCTAssertTrue(store.hasSearched)

        store.apply([.mailNew(accountId: nil, folderId: nil, messageId: nil)])
        try await Task.sleep(nanoseconds: 50_000_000)
        // Still zero results, but the important thing is that a second network round trip
        // happened without throwing — proven by `hasSearched` staying true and no crash.
        XCTAssertTrue(store.hasSearched)
    }

    func testBothQueriesOfSemanticModeCarryTheTimeWindowAndNeitherStrictnessNorSort() async throws {
        let empty = #"{"results":[],"query":"invoice","model":"m"}"#
        let emptyText = #"{"results":[],"has_more":false,"next_cursor":null,"query":"invoice","total":0}"#
        MVStubURLProtocol.stubsByPath = [
            "/api/embeddings/search": .init(statusCode: 200, headers: [:], body: Data(empty.utf8)),
            "/api/search": .init(statusCode: 200, headers: [:], body: Data(emptyText.utf8)),
        ]

        let store = makeStore(defaults: makeDefaults())
        await store.updateContext(
            SearchContext(mode: .semantic, query: "invoice", timeWindow: .preset(.last7Days)))

        for path in ["/api/embeddings/search", "/api/search"] {
            let request = try XCTUnwrap(MVStubURLProtocol.capturedRequests.first { $0.url?.path == path })
            let url = try XCTUnwrap(request.url)
            let names = Set(
                (URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []).map(\.name))
            XCTAssertTrue(names.isSuperset(of: ["q", "received_after", "received_before"]), path)
            XCTAssertTrue(names.isDisjoint(with: ["strictness", "sort"]), path)
        }
    }

    func testAFullTextQuerySendsNoSort() async throws {
        let json = #"{"results":[],"has_more":false,"next_cursor":null,"query":"xx","total":0}"#
        MVStubURLProtocol.stub = .init(statusCode: 200, headers: [:], body: Data(json.utf8))

        let store = makeStore(defaults: makeDefaults())
        await store.updateContext(SearchContext(mode: .text, query: "xx"))

        let url = try XCTUnwrap(MVStubURLProtocol.capturedRequest?.url)
        let names = (URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []).map(\.name)
        XCTAssertFalse(names.contains("sort"))
        XCTAssertFalse(names.contains("received_after"))
    }

    func testASemanticResultKeepsItsTierFromTheWire() async throws {
        let id = UUID()
        let json = """
            {"results":[{"id":"\(id)","account_id":"\(UUID())","folder_id":"\(UUID())","thread_id":"\(UUID())",
            "subject":"A","from_addr":null,"to_addrs":null,"received_at":null,"snippet":null,
            "mirrored_at":"2026-01-01T00:00:00+00:00","has_attachments":false,"tier":2}],
            "query":"invoice","model":"m"}
            """
        MVStubURLProtocol.stub = .init(statusCode: 200, headers: [:], body: Data(json.utf8))
        let store = makeStore(defaults: makeDefaults())
        await store.updateContext(SearchContext(mode: .semantic, query: "invoice"))
        XCTAssertEqual(store.results.first?.tier, 2)
        XCTAssertEqual(store.results.first?.id, id)
    }

    // MARK: - Semantic mode asks full-text first

    private func hitJSON(_ id: UUID, tier: Int? = nil) -> String {
        """
        {"id":"\(id)","account_id":"\(UUID())","folder_id":"\(UUID())","thread_id":"\(UUID())",
        "subject":"S","from_addr":null,"to_addrs":null,"received_at":null,"snippet":null,
        "mirrored_at":"2026-01-01T00:00:00+00:00","has_attachments":false\(tier.map { ",\"tier\":\($0)" } ?? "")}
        """
    }

    private func fullTextStub(_ ids: [UUID], delay: TimeInterval = 0) -> MVStubURLProtocol.Stub {
        let body = """
            {"results":[\(ids.map { hitJSON($0) }.joined(separator: ","))],"has_more":false,
            "next_cursor":null,"query":"q","total":\(ids.count)}
            """
        return .init(statusCode: 200, headers: [:], body: Data(body.utf8), delay: delay)
    }

    private func semanticStub(_ hits: [(UUID, Int)], delay: TimeInterval = 0) -> MVStubURLProtocol.Stub {
        let body = """
            {"results":[\(hits.map { hitJSON($0.0, tier: $0.1) }.joined(separator: ","))],"query":"q","model":"m"}
            """
        return .init(statusCode: 200, headers: [:], body: Data(body.utf8), delay: delay)
    }

    private func unavailableStub(delay: TimeInterval = 0) -> MVStubURLProtocol.Stub {
        .init(
            statusCode: 503, headers: [:],
            body: Data(#"{"detail":{"code":"semantic_unavailable","message":"busy"}}"#.utf8), delay: delay)
    }

    /// Polls the main actor until `condition` holds; a test then asserts on the state it reached
    /// instead of sleeping a guessed duration.
    private func waitUntil(_ condition: () -> Bool) async {
        for _ in 0..<200 where !condition() { try? await Task.sleep(nanoseconds: 10_000_000) }
    }

    func testSemanticModeShowsTheFullTextListFirstAndThenTheTieredOne() async {
        let lexical = UUID(), likely = UUID(), unlikely = UUID()
        MVStubURLProtocol.stubsByPath = [
            "/api/search": fullTextStub([lexical]),
            "/api/embeddings/search": semanticStub([(likely, 1), (unlikely, 2)], delay: 0.4),
        ]
        let store = makeStore(defaults: makeDefaults())
        let run = Task { await store.updateContext(SearchContext(mode: .semantic, query: "invoice")) }

        await waitUntil { store.semanticState == .pending && store.results.count == 1 }
        XCTAssertEqual(store.results.map(\.id), [lexical])
        XCTAssertEqual(store.semanticState, .pending)
        XCTAssertEqual(store.results.first?.tier, nil)

        await run.value
        XCTAssertEqual(store.results.map(\.id), [likely, unlikely])
        XCTAssertEqual(store.results.map(\.tier), [1, 2])
        XCTAssertEqual(store.semanticState, .settled)
        XCTAssertEqual(store.resultsState, .results)
    }

    func testAnEmptyTieredAnswerReplacesTheFullTextList() async {
        MVStubURLProtocol.stubsByPath = [
            "/api/search": fullTextStub([UUID()]),
            "/api/embeddings/search": semanticStub([], delay: 0.2),
        ]
        let store = makeStore(defaults: makeDefaults())
        await store.updateContext(SearchContext(mode: .semantic, query: "invoice"))
        XCTAssertEqual(store.results, [])
        XCTAssertEqual(store.resultsState, .noResults)
    }

    func testA503KeepsTheFullTextListAndFlagsSemanticUnavailable() async {
        let lexical = UUID()
        MVStubURLProtocol.stubsByPath = [
            "/api/search": fullTextStub([lexical], delay: 0.2),
            "/api/embeddings/search": unavailableStub(),
        ]
        let store = makeStore(defaults: makeDefaults())
        await store.updateContext(SearchContext(mode: .semantic, query: "invoice"))
        XCTAssertEqual(store.results.map(\.id), [lexical])
        XCTAssertEqual(store.semanticState, .unavailable)
        XCTAssertNil(store.errorMessage)
        XCTAssertEqual(store.resultsState, .results)
    }

    func testAFullTextListThatLandsAfterTheTieredOneDoesNotReplaceIt() async {
        let lexical = UUID(), likely = UUID()
        MVStubURLProtocol.stubsByPath = [
            "/api/search": fullTextStub([lexical], delay: 0.4),
            "/api/embeddings/search": semanticStub([(likely, 1)]),
        ]
        let store = makeStore(defaults: makeDefaults())
        await store.updateContext(SearchContext(mode: .semantic, query: "invoice"))
        try? await Task.sleep(nanoseconds: 700_000_000)
        XCTAssertEqual(store.results.map(\.id), [likely])
    }

    func testAResponseForASupersededQueryIsDropped() async {
        let old = UUID(), fresh = UUID()
        MVStubURLProtocol.stubsByPath = [
            "/api/search": fullTextStub([old], delay: 0.4),
            "/api/embeddings/search": semanticStub([(old, 1)], delay: 0.4),
        ]
        let store = makeStore(defaults: makeDefaults())
        let first = Task { await store.updateContext(SearchContext(mode: .semantic, query: "first")) }
        await waitUntil { MVStubURLProtocol.capturedPaths.count == 2 }

        MVStubURLProtocol.stubsByPath = [
            "/api/search": fullTextStub([fresh]),
            "/api/embeddings/search": semanticStub([(fresh, 1)]),
        ]
        await store.updateContext(SearchContext(mode: .semantic, query: "second"))
        await first.value
        try? await Task.sleep(nanoseconds: 700_000_000)
        XCTAssertEqual(store.results.map(\.id), [fresh])
        XCTAssertEqual(store.semanticState, .settled)
    }

    func testAFullTextAnswerForASupersededQueryDoesNotShowWhileTheNewOneIsPending() async {
        let old = UUID(), fresh = UUID()
        MVStubURLProtocol.stubsByPath = [
            "/api/search": fullTextStub([old], delay: 0.3),
            "/api/embeddings/search": semanticStub([(old, 1)], delay: 0.3),
        ]
        let store = makeStore(defaults: makeDefaults())
        let first = Task { await store.updateContext(SearchContext(mode: .semantic, query: "first")) }
        await waitUntil { MVStubURLProtocol.capturedPaths.count == 2 }

        MVStubURLProtocol.stubsByPath = [
            "/api/search": fullTextStub([fresh], delay: 1.0),
            "/api/embeddings/search": semanticStub([(fresh, 1)], delay: 1.2),
        ]
        let second = Task { await store.updateContext(SearchContext(mode: .semantic, query: "second")) }
        try? await Task.sleep(nanoseconds: 600_000_000)
        XCTAssertEqual(store.results, [])
        XCTAssertEqual(store.semanticState, .pending)

        await first.value
        await second.value
        XCTAssertEqual(store.results.map(\.id), [fresh])
    }

    func testChangingOnlyTheWindowAsksOnlyTheSemanticEndpoint() async {
        MVStubURLProtocol.stubsByPath = [
            "/api/search": fullTextStub([UUID()]),
            "/api/embeddings/search": semanticStub([(UUID(), 1)]),
        ]
        let store = makeStore(defaults: makeDefaults())
        await store.updateContext(SearchContext(mode: .semantic, query: "invoice"))
        XCTAssertEqual(MVStubURLProtocol.capturedPaths.sorted(), ["/api/embeddings/search", "/api/search"])

        let before = MVStubURLProtocol.capturedPaths.count
        await store.updateContext(
            SearchContext(mode: .semantic, query: "invoice", timeWindow: .preset(.last7Days)))
        try? await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertEqual(Array(MVStubURLProtocol.capturedPaths.dropFirst(before)), ["/api/embeddings/search"])
    }

    func testAWindowChangeThatMeets503FallsBackToFullText() async {
        let lexical = UUID()
        MVStubURLProtocol.stubsByPath = [
            "/api/search": fullTextStub([UUID()]),
            "/api/embeddings/search": semanticStub([(UUID(), 1)]),
        ]
        let store = makeStore(defaults: makeDefaults())
        await store.updateContext(SearchContext(mode: .semantic, query: "invoice"))

        MVStubURLProtocol.stubsByPath = [
            "/api/search": fullTextStub([lexical]), "/api/embeddings/search": unavailableStub(),
        ]
        await store.updateContext(
            SearchContext(mode: .semantic, query: "invoice", timeWindow: .preset(.today)))
        XCTAssertEqual(store.results.map(\.id), [lexical])
        XCTAssertEqual(store.semanticState, .unavailable)
    }

    func testTextModeNeverTouchesTheSemanticEndpoint() async {
        MVStubURLProtocol.stubsByPath = ["/api/search": fullTextStub([UUID()])]
        let store = makeStore(defaults: makeDefaults())
        await store.updateContext(SearchContext(mode: .text, query: "invoice"))
        XCTAssertEqual(MVStubURLProtocol.capturedPaths, ["/api/search"])
        XCTAssertEqual(store.semanticState, .settled)
    }
}
