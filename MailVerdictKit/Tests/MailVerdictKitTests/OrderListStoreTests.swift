import XCTest
@testable import MailVerdictKit

@MainActor
final class OrderListStoreTests: XCTestCase {

    override func tearDown() {
        MVStubURLProtocol.reset()
        super.tearDown()
    }

    private func makeStore(filter: OrderListStore.Filter = .all) -> OrderListStore {
        let factory = try! MVRequestFactory(baseURL: "https://stub.example.com", authProvider: { .none })
        let client = MVApiClient(requestFactory: factory, urlSession: MVStubURLProtocol.makeSession())
        return OrderListStore(apiClient: client, filter: filter)
    }

    private func itemJSON(
        id: UUID, lastMailAt: String = "2026-04-23T10:00:00+00:00", accountId: UUID = UUID()
    ) -> String {
        """
        {"id":"\(id)","merchant":"Nordlicht Keramik","subject":"Your order","status":"shipped",
        "title":"Your order — shipped","is_open":true,"icon":"package",
        "summary_preview":"On its way","first_mail_at":"2026-04-21T09:00:00+00:00",
        "last_mail_at":"\(lastMailAt)","mail_count":2,"account_ids":["\(accountId)"],
        "text_stale":false,"updated_at":"\(lastMailAt)"}
        """
    }

    func testLoadPopulatesRows() async {
        let a = UUID()
        MVStubURLProtocol.stub = .init(
            statusCode: 200, headers: [:],
            body: Data("{\"items\":[\(itemJSON(id: a))],\"has_more\":false,\"next_cursor\":null}".utf8))
        let store = makeStore()
        await store.load()
        XCTAssertEqual(store.rows.map(\.id), [a])
        XCTAssertNil(store.errorMessage)
        XCTAssertTrue(store.held.isEmpty)
    }

    func testLoadFailurePopulatesErrorMessage() async {
        MVStubURLProtocol.stub = .init(statusCode: 500, headers: [:], body: Data(#"{"detail":"boom"}"#.utf8))
        let store = makeStore()
        await store.load()
        XCTAssertEqual(store.errorMessage, "boom")
        XCTAssertEqual(store.rows, [])
    }

    func testLoadMoreAppendsAndTracksTheCursor() async {
        let a = UUID(), b = UUID()
        MVStubURLProtocol.stub = .init(
            statusCode: 200, headers: [:],
            body: Data("{\"items\":[\(itemJSON(id: a))],\"has_more\":true,\"next_cursor\":\"\(a)\"}".utf8))
        let store = makeStore()
        await store.load()

        MVStubURLProtocol.stub = .init(
            statusCode: 200, headers: [:],
            body: Data("{\"items\":[\(itemJSON(id: b))],\"has_more\":false,\"next_cursor\":null}".utf8))
        await store.loadMore()

        XCTAssertEqual(store.rows.map(\.id), [a, b])
        XCTAssertFalse(store.hasMore)
    }

    func testSetFilterReloadsWithTheNewState() async {
        let a = UUID()
        MVStubURLProtocol.stub = .init(
            statusCode: 200, headers: [:],
            body: Data("{\"items\":[\(itemJSON(id: a))],\"has_more\":false,\"next_cursor\":null}".utf8))
        let store = makeStore()
        await store.setFilter(.open)
        XCTAssertEqual(store.filter, .open)
        XCTAssertEqual(MVStubURLProtocol.capturedRequest?.url?.query?.contains("state=open"), true)
        XCTAssertEqual(store.rows.map(\.id), [a])
    }

    // MARK: - Live updates (the no-jump rule)

    func testALiveUpdateAtTheTopAdoptsTheFreshOrderAtOnce() async throws {
        let existing = UUID(), fresh = UUID()
        MVStubURLProtocol.stub = .init(
            statusCode: 200, headers: [:],
            body: Data("{\"items\":[\(itemJSON(id: existing))],\"has_more\":false,\"next_cursor\":null}".utf8))
        let store = makeStore()
        await store.load()

        store.isAtTop = true
        MVStubURLProtocol.stub = .init(
            statusCode: 200, headers: [:],
            body: Data(
                "{\"items\":[\(itemJSON(id: fresh)),\(itemJSON(id: existing))],\"has_more\":false,\"next_cursor\":null}"
                    .utf8))
        store.apply([.orderChanged(orderId: fresh, change: "created")])
        try await Task.sleep(nanoseconds: 50_000_000)

        XCTAssertEqual(store.rows.map(\.id), [fresh, existing])
        XCTAssertTrue(store.held.isEmpty)
    }

    func testALiveUpdateScrolledDownHoldsBackTheNewOrderUntilTakenOver() async throws {
        let existing = UUID(), fresh = UUID()
        MVStubURLProtocol.stub = .init(
            statusCode: 200, headers: [:],
            body: Data("{\"items\":[\(itemJSON(id: existing))],\"has_more\":false,\"next_cursor\":null}".utf8))
        let store = makeStore()
        await store.load()

        store.isAtTop = false
        MVStubURLProtocol.stub = .init(
            statusCode: 200, headers: [:],
            body: Data(
                "{\"items\":[\(itemJSON(id: fresh)),\(itemJSON(id: existing))],\"has_more\":false,\"next_cursor\":null}"
                    .utf8))
        store.apply([.orderChanged(orderId: fresh, change: "created")])
        try await Task.sleep(nanoseconds: 50_000_000)

        XCTAssertEqual(store.rows.map(\.id), [existing])
        XCTAssertEqual(store.held.map(\.id), [fresh])

        store.takeOverHeld()
        XCTAssertEqual(store.rows.map(\.id), [fresh, existing])
        XCTAssertTrue(store.held.isEmpty)
    }

    /// The regression this guards: an order already visible before the hold that also received new
    /// mail during it moves in the server's own order too, ahead of even the order that newly
    /// arrived -- `held + previously shown` (the earlier `takeOverHeld` implementation) could never
    /// see that, since it always puts every held row ahead of every previously-shown one regardless
    /// of the server's actual order.
    func testTakeOverMovesABumpedExistingOrderToItsFreshPositionAheadOfTheNewOne() async throws {
        let bumped = UUID(), other = UUID(), brandNew = UUID()
        MVStubURLProtocol.stub = .init(
            statusCode: 200, headers: [:],
            body: Data(
                "{\"items\":[\(itemJSON(id: bumped)),\(itemJSON(id: other))],\"has_more\":false,\"next_cursor\":null}"
                    .utf8))
        let store = makeStore()
        await store.load()

        store.isAtTop = false
        // bumped received new mail of its own during the hold, moving it ahead of brandNew --
        // the order arriving is not simply prepended to what was already there.
        MVStubURLProtocol.stub = .init(
            statusCode: 200, headers: [:],
            body: Data(
                "{\"items\":[\(itemJSON(id: bumped)),\(itemJSON(id: brandNew)),\(itemJSON(id: other))],\"has_more\":false,\"next_cursor\":null}"
                    .utf8))
        store.apply([.orderChanged(orderId: brandNew, change: "created")])
        try await Task.sleep(nanoseconds: 50_000_000)

        XCTAssertEqual(store.rows.map(\.id), [bumped, other])
        XCTAssertEqual(store.held.map(\.id), [brandNew])

        store.takeOverHeld()
        XCTAssertEqual(store.rows.map(\.id), [bumped, brandNew, other])
        XCTAssertTrue(store.held.isEmpty)
    }

    func testResyncAlwaysReloadsRegardlessOfScrollPosition() async throws {
        let a = UUID()
        MVStubURLProtocol.stub = .init(
            statusCode: 200, headers: [:],
            body: Data("{\"items\":[\(itemJSON(id: a))],\"has_more\":false,\"next_cursor\":null}".utf8))
        let store = makeStore()
        await store.load()

        store.isAtTop = false
        store.apply([.resync])
        try await Task.sleep(nanoseconds: 50_000_000)

        XCTAssertEqual(store.rows.map(\.id), [a])
    }

    func testAnUnrelatedInvalidationIsIgnored() async throws {
        let a = UUID()
        MVStubURLProtocol.stub = .init(
            statusCode: 200, headers: [:],
            body: Data("{\"items\":[\(itemJSON(id: a))],\"has_more\":false,\"next_cursor\":null}".utf8))
        let store = makeStore()
        await store.load()

        MVStubURLProtocol.stub = .init(statusCode: 500, headers: [:], body: Data())
        store.apply([.foldersChanged])
        try await Task.sleep(nanoseconds: 50_000_000)

        XCTAssertEqual(store.rows.map(\.id), [a])
        XCTAssertNil(store.errorMessage)
    }

    // MARK: - Favorites, filter field and row actions

    private func detailJSON(id: UUID, isFavorite: Bool = false, isOpen: Bool = true) -> String {
        """
        {"id":"\(id)","merchant":"Nordlicht Keramik","subject":"Your order","status":"shipped",
        "title":"Your order — shipped","is_open":\(isOpen),"is_favorite":\(isFavorite),"icon":"package",
        "summary_preview":"On its way","first_mail_at":"2026-04-21T09:00:00+00:00",
        "last_mail_at":"2026-04-23T10:00:00+00:00","mail_count":2,"account_ids":[],
        "text_stale":false,"updated_at":"2026-04-23T10:00:00+00:00","summary":"s",
        "identifiers":[],"mails":[],"documents":[]}
        """
    }

    private func stubList(_ ids: [UUID]) {
        let items = ids.map { itemJSON(id: $0) }.joined(separator: ",")
        MVStubURLProtocol.stub = .init(
            statusCode: 200, headers: [:],
            body: Data("{\"items\":[\(items)],\"has_more\":false,\"next_cursor\":null}".utf8))
    }

    func testFavoritesFilterAsksForAllStateWithTheFavoritesFlag() async {
        stubList([UUID()])
        let store = makeStore()
        await store.setFilter(.favorites)
        let query = MVStubURLProtocol.capturedRequest?.url?.query ?? ""
        XCTAssertTrue(query.contains("state=all"))
        XCTAssertTrue(query.contains("favorites=true"))
    }

    func testTheFilterFieldReloadsOnceTypingPausesAndSendsTheText() async throws {
        stubList([UUID()])
        let factory = try! MVRequestFactory(baseURL: "https://stub.example.com", authProvider: { .none })
        let client = MVApiClient(requestFactory: factory, urlSession: MVStubURLProtocol.makeSession())
        let store = OrderListStore(apiClient: client, queryDebounce: .milliseconds(20))
        store.setQuery("nord")
        store.setQuery("nordlicht ")
        XCTAssertNil(MVStubURLProtocol.capturedRequest)
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(store.query, "nordlicht")
        XCTAssertEqual(MVStubURLProtocol.capturedRequest?.url?.query?.contains("q=nordlicht"), true)
        XCTAssertEqual(store.rows.count, 1)
    }

    func testFavoritingARowPatchesItAndReplacesTheRowInPlace() async throws {
        let a = UUID()
        stubList([a])
        let store = makeStore()
        await store.load()

        MVStubURLProtocol.stub = .init(
            statusCode: 200, headers: [:], body: Data(detailJSON(id: a, isFavorite: true).utf8))
        let message = try await store.perform(.favorite, on: store.rows[0])

        XCTAssertEqual(message, "Added to favorites")
        XCTAssertEqual(MVStubURLProtocol.capturedRequest?.httpMethod, "PATCH")
        XCTAssertEqual(MVStubURLProtocol.capturedRequest?.url?.path, "/api/orders/\(a)")
        let body = try XCTUnwrap(MVStubURLProtocol.capturedRequest?.httpBody)
        XCTAssertEqual(
            try JSONDecoder().decode(OrderUpdateRequest.self, from: body),
            OrderUpdateRequest(isFavorite: true))
        XCTAssertEqual(store.rows.map(\.isFavorite), [true])
    }

    func testClosingAnOpenRowSendsIsOpenFalse() async throws {
        let a = UUID()
        stubList([a])
        let store = makeStore()
        await store.load()

        MVStubURLProtocol.stub = .init(
            statusCode: 200, headers: [:], body: Data(detailJSON(id: a, isOpen: false).utf8))
        try await store.perform(.close, on: store.rows[0])

        let body = try XCTUnwrap(MVStubURLProtocol.capturedRequest?.httpBody)
        XCTAssertEqual(
            try JSONDecoder().decode(OrderUpdateRequest.self, from: body),
            OrderUpdateRequest(isOpen: false))
        XCTAssertEqual(store.rows.map(\.isOpen), [false])
    }

    func testDeletingARowRemovesIt() async throws {
        let a = UUID(), b = UUID()
        stubList([a, b])
        let store = makeStore()
        await store.load()

        MVStubURLProtocol.stub = .init(statusCode: 204, headers: [:], body: Data())
        try await store.perform(.delete, on: store.rows[0])

        XCTAssertEqual(MVStubURLProtocol.capturedRequest?.httpMethod, "DELETE")
        XCTAssertEqual(store.rows.map(\.id), [b])
    }
}
