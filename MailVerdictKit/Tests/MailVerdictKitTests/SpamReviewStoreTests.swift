import XCTest
@testable import MailVerdictKit

@MainActor
final class SpamReviewStoreTests: XCTestCase {

    override func tearDown() {
        MVStubURLProtocol.reset()
        super.tearDown()
    }

    private func makeStore() -> SpamReviewStore {
        let factory = try! MVRequestFactory(baseURL: "https://stub.example.com", authProvider: { .none })
        let client = MVApiClient(requestFactory: factory, urlSession: MVStubURLProtocol.makeSession())
        return SpamReviewStore(apiClient: client)
    }

    private func itemJSON(messageId: UUID, accountId: UUID = UUID(), isJunk: Bool = true) -> String {
        """
        {"message_id":"\(messageId)","account_id":"\(accountId)","folder_id":"\(UUID())",
        "is_junk":\(isJunk),"subject":"Win big","from_addr":"spam@example.com","received_at":null,
        "snippet":"Click now","verdict_id":"\(UUID())","model_used":"gpt","reasoning":"looks spammy",
        "verdict_created_at":"2026-01-01T00:00:00+00:00"}
        """
    }

    func testLoadPopulatesItemsAndReaderTitle() async {
        let a = UUID()
        let json = """
            {"items":[\(itemJSON(messageId: a))],"has_more":false,"next_cursor":null}
            """
        MVStubURLProtocol.stub = .init(statusCode: 200, headers: [:], body: Data(json.utf8))

        let store = makeStore()
        await store.load()

        XCTAssertEqual(store.items.map(\.messageId), [a])
        XCTAssertEqual(store.readerTitle, "1 to Review")
        XCTAssertNil(store.errorMessage)
    }

    func testReaderTitleGetsATrailingPlusWhenMoreIsKnownToExist() async {
        let a = UUID()
        let json = """
            {"items":[\(itemJSON(messageId: a))],"has_more":true,"next_cursor":"\(UUID())"}
            """
        MVStubURLProtocol.stub = .init(statusCode: 200, headers: [:], body: Data(json.utf8))
        let store = makeStore()
        await store.load()
        XCTAssertEqual(store.readerTitle, "1+ to Review")
    }

    func testApplyingVerdictIssuedReloads() async throws {
        let store = makeStore()
        let a = UUID()
        MVStubURLProtocol.stub = .init(
            statusCode: 200, headers: [:],
            body: Data("{\"items\":[\(itemJSON(messageId: a))],\"has_more\":false,\"next_cursor\":null}".utf8))

        store.apply([.verdictIssued(accountId: nil, messageId: a, isSpam: true)])
        try await Task.sleep(nanoseconds: 50_000_000)

        XCTAssertEqual(store.items.map(\.messageId), [a])
    }

    func testLoadFailurePopulatesErrorMessage() async {
        MVStubURLProtocol.stub = .init(statusCode: 500, headers: [:], body: Data(#"{"detail":"boom"}"#.utf8))
        let store = makeStore()
        await store.load()
        XCTAssertEqual(store.errorMessage, "boom")
        XCTAssertEqual(store.items, [])
    }

    func testDecideRemovesTheRowOnSuccess() async throws {
        let a = UUID(), accountId = UUID()
        let listJSON = """
            {"items":[\(itemJSON(messageId: a, accountId: accountId))],"has_more":false,"next_cursor":null}
            """
        MVStubURLProtocol.stub = .init(statusCode: 200, headers: [:], body: Data(listJSON.utf8))
        let store = makeStore()
        await store.load()
        XCTAssertEqual(store.items.count, 1)

        let feedbackJSON = """
            {"success":true,"message_id":"\(a)","is_spam":true,"message":null}
            """
        MVStubURLProtocol.stub = .init(statusCode: 200, headers: [:], body: Data(feedbackJSON.utf8))
        try await store.decide(store.items[0], agree: true)

        XCTAssertEqual(store.items, [])
    }

    func testDecideAllClearsEveryLoadedRowOnSuccess() async {
        let a = UUID(), b = UUID()
        let listJSON = """
            {"items":[\(itemJSON(messageId: a)),\(itemJSON(messageId: b))],"has_more":false,"next_cursor":null}
            """
        MVStubURLProtocol.stub = .init(statusCode: 200, headers: [:], body: Data(listJSON.utf8))
        let store = makeStore()
        await store.load()

        MVStubURLProtocol.stub = .init(
            statusCode: 200, headers: [:], body: Data(#"{"success":true,"message_id":"\#(a)","is_spam":true}"#.utf8))
        let result = await store.decideAll(agree: true)

        XCTAssertEqual(result.attempted, 2)
        XCTAssertEqual(result.succeeded, 2)
        XCTAssertEqual(result.failed, 0)
        XCTAssertEqual(store.items, [])
    }

    func testReaderListSourceNeighboursWalkLoadedOrder() async {
        let a = UUID(), b = UUID()
        let json = """
            {"items":[\(itemJSON(messageId: a)),\(itemJSON(messageId: b))],"has_more":false,"next_cursor":null}
            """
        MVStubURLProtocol.stub = .init(statusCode: 200, headers: [:], body: Data(json.utf8))
        let store = makeStore()
        await store.load()

        XCTAssertEqual(store.rowIds, [a, b])
        XCTAssertEqual(store.neighbours(of: a).older, b)
        XCTAssertNil(store.neighbours(of: a).newer)
        XCTAssertFalse(store.hasNewer)
    }
}
