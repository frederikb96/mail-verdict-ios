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
}
