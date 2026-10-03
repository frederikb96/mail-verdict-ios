import XCTest
@testable import MailVerdictKit

@MainActor
final class OrderDetailStoreTests: XCTestCase {

    override func tearDown() {
        MVStubURLProtocol.reset()
        super.tearDown()
    }

    private func makeStore(orderId: UUID) -> OrderDetailStore {
        let factory = try! MVRequestFactory(baseURL: "https://stub.example.com", authProvider: { .none })
        let client = MVApiClient(requestFactory: factory, urlSession: MVStubURLProtocol.makeSession())
        return OrderDetailStore(orderId: orderId, apiClient: client)
    }

    private func mailJSON(
        key: UUID, messageId: UUID?, location: String, accountId: UUID = UUID()
    ) -> String {
        let messageIdField = messageId.map { "\"\($0)\"" } ?? "null"
        return """
            {"key":"\(key)","account_id":"\(accountId)","message_id":\(messageIdField),
            "thread_id":null,"location":"\(location)","folder_id":null,"is_seen":true,
            "subject":"Your order","from_addr":"shop@example.com",
            "received_at":"2026-04-21T09:00:00+00:00","attached_by":"ai"}
            """
    }

    private func detailJSON(id: UUID, mails: String, documents: String = "[]") -> String {
        """
        {"id":"\(id)","merchant":"Nordlicht Keramik","subject":"Your order","status":"shipped",
        "title":"Your order — shipped","is_open":true,"icon":"package",
        "summary_preview":"On its way","first_mail_at":"2026-04-21T09:00:00+00:00",
        "last_mail_at":"2026-04-23T10:00:00+00:00","mail_count":2,"account_ids":[],
        "text_stale":false,"updated_at":"2026-04-23T10:00:00+00:00","summary":"**Total:** EUR 49.90",
        "identifiers":[],"mails":[\(mails)],"documents":\(documents)}
        """
    }

    func testLoadPopulatesTheOrder() async {
        let orderId = UUID(), mailKey = UUID(), messageId = UUID()
        MVStubURLProtocol.stub = .init(
            statusCode: 200, headers: [:],
            body: Data(
                detailJSON(id: orderId, mails: mailJSON(key: mailKey, messageId: messageId, location: "mailbox")).utf8)
        )
        let store = makeStore(orderId: orderId)
        await store.load()
        XCTAssertEqual(store.order?.id, orderId)
        XCTAssertEqual(store.order?.mails.first?.key, mailKey)
        XCTAssertFalse(store.wasDeleted)
    }

    func testA404OnLoadReportsTheOrderAsDeleted() async {
        let orderId = UUID()
        MVStubURLProtocol.stub = .init(
            statusCode: 404, headers: [:], body: Data(#"{"detail":"Order not found"}"#.utf8))
        let store = makeStore(orderId: orderId)
        await store.load()
        XCTAssertTrue(store.wasDeleted)
        XCTAssertNil(store.errorMessage)
    }

    /// A "gone" mail carries no `messageId` -- the reader source must never try to open it, and
    /// the screen reads `isGone` to render it dimmed.
    func testAGoneMailIsExcludedFromTheOpenableRowsAndFlaggedGone() async {
        let orderId = UUID()
        let openMailKey = UUID(), openMessageId = UUID()
        let goneMailKey = UUID()
        let mails =
            "\(mailJSON(key: openMailKey, messageId: openMessageId, location: "mailbox")),"
            + mailJSON(key: goneMailKey, messageId: nil, location: "gone")
        MVStubURLProtocol.stub = .init(
            statusCode: 200, headers: [:], body: Data(detailJSON(id: orderId, mails: mails).utf8))
        let store = makeStore(orderId: orderId)
        await store.load()

        XCTAssertEqual(store.order?.mails.count, 2)
        XCTAssertEqual(store.order?.mails.last?.isGone, true)
        XCTAssertEqual(store.rowIds, [openMessageId])
    }

    func testReaderTitleNamesTheMailCount() async {
        let orderId = UUID(), mailKey = UUID(), messageId = UUID()
        MVStubURLProtocol.stub = .init(
            statusCode: 200, headers: [:],
            body: Data(
                detailJSON(id: orderId, mails: mailJSON(key: mailKey, messageId: messageId, location: "mailbox")).utf8)
        )
        let store = makeStore(orderId: orderId)
        await store.load()
        XCTAssertEqual(store.readerTitle, "2 Mails")
    }

    func testDeleteMarksTheOrderDeleted() async throws {
        let orderId = UUID()
        MVStubURLProtocol.stub = .init(statusCode: 204, headers: [:], body: Data())
        let store = makeStore(orderId: orderId)
        try await store.delete()
        XCTAssertTrue(store.wasDeleted)
        XCTAssertEqual(MVStubURLProtocol.capturedRequest?.httpMethod, "DELETE")
        XCTAssertEqual(MVStubURLProtocol.capturedRequest?.url?.path, "/api/orders/\(orderId)")
    }

    func testRewriteSendsThePostRouteTheServerExpects() async throws {
        let orderId = UUID()
        MVStubURLProtocol.stub = .init(statusCode: 202, headers: [:], body: Data())
        let store = makeStore(orderId: orderId)
        try await store.rewrite()
        XCTAssertEqual(MVStubURLProtocol.capturedRequest?.httpMethod, "POST")
        XCTAssertEqual(MVStubURLProtocol.capturedRequest?.url?.path, "/api/orders/\(orderId)/rewrite")
    }

    func testDetachingTheLastMailReportsTheOrderDeleted() async throws {
        let orderId = UUID(), mailKey = UUID(), messageId = UUID()
        MVStubURLProtocol.stub = .init(
            statusCode: 200, headers: [:],
            body: Data(
                detailJSON(id: orderId, mails: mailJSON(key: mailKey, messageId: messageId, location: "mailbox")).utf8)
        )
        let store = makeStore(orderId: orderId)
        await store.load()

        MVStubURLProtocol.stub = .init(statusCode: 204, headers: [:], body: Data())
        try await store.detachMail(store.order!.mails[0])
        XCTAssertTrue(store.wasDeleted)
        XCTAssertEqual(MVStubURLProtocol.capturedRequest?.httpMethod, "POST")
        XCTAssertEqual(
            MVStubURLProtocol.capturedRequest?.url?.path, "/api/orders/\(orderId)/mails/\(mailKey)/detach")
        let body = try XCTUnwrap(MVStubURLProtocol.capturedRequest?.httpBody)
        XCTAssertNil(try JSONDecoder().decode(OrderDetachRequest.self, from: body).moveTo)
    }

    func testDetachingOneOfSeveralMailsUpdatesTheOrderInPlace() async throws {
        let orderId = UUID(), a = UUID(), aMsg = UUID(), b = UUID(), bMsg = UUID()
        let mails =
            "\(mailJSON(key: a, messageId: aMsg, location: "mailbox")),"
            + mailJSON(key: b, messageId: bMsg, location: "mailbox")
        MVStubURLProtocol.stub = .init(
            statusCode: 200, headers: [:], body: Data(detailJSON(id: orderId, mails: mails).utf8))
        let store = makeStore(orderId: orderId)
        await store.load()

        MVStubURLProtocol.stub = .init(
            statusCode: 200, headers: [:],
            body: Data(detailJSON(id: orderId, mails: mailJSON(key: b, messageId: bMsg, location: "mailbox")).utf8))
        try await store.detachMail(store.order!.mails[0])

        XCTAssertFalse(store.wasDeleted)
        XCTAssertEqual(store.order?.mails.map(\.key), [b])
    }

    func testALiveDeletedEventForThisOrderMarksItDeletedWithoutRefetching() async throws {
        let orderId = UUID(), mailKey = UUID(), messageId = UUID()
        MVStubURLProtocol.stub = .init(
            statusCode: 200, headers: [:],
            body: Data(
                detailJSON(id: orderId, mails: mailJSON(key: mailKey, messageId: messageId, location: "mailbox")).utf8)
        )
        let store = makeStore(orderId: orderId)
        await store.load()

        MVStubURLProtocol.stub = .init(statusCode: 500, headers: [:], body: Data())
        store.apply([.orderChanged(orderId: orderId, change: "deleted")])
        try await Task.sleep(nanoseconds: 50_000_000)

        XCTAssertTrue(store.wasDeleted)
    }

    func testALiveUpdateForAnotherOrderIsIgnored() async throws {
        let orderId = UUID(), mailKey = UUID(), messageId = UUID()
        MVStubURLProtocol.stub = .init(
            statusCode: 200, headers: [:],
            body: Data(
                detailJSON(id: orderId, mails: mailJSON(key: mailKey, messageId: messageId, location: "mailbox")).utf8)
        )
        let store = makeStore(orderId: orderId)
        await store.load()

        MVStubURLProtocol.stub = .init(statusCode: 500, headers: [:], body: Data())
        store.apply([.orderChanged(orderId: UUID(), change: "deleted")])
        try await Task.sleep(nanoseconds: 50_000_000)

        XCTAssertFalse(store.wasDeleted)
        XCTAssertNotNil(store.order)
    }

    func testSealingPatchesTheOrderAndAdoptsTheServersAnswer() async throws {
        let orderId = UUID()
        MVStubURLProtocol.stub = .init(
            statusCode: 200, headers: [:], body: Data(detailJSON(id: orderId, mails: "").utf8))
        let store = makeStore(orderId: orderId)
        await store.load()
        XCTAssertEqual(store.order?.isSealed, false)

        let sealed = detailJSON(id: orderId, mails: "").replacingOccurrences(
            of: "\"icon\":", with: "\"is_sealed\":true,\"icon\":")
        MVStubURLProtocol.stub = .init(statusCode: 200, headers: [:], body: Data(sealed.utf8))
        let message = try await store.perform(.seal)

        XCTAssertEqual(message, "Order sealed")
        XCTAssertEqual(MVStubURLProtocol.capturedRequest?.httpMethod, "PATCH")
        let body = try XCTUnwrap(MVStubURLProtocol.capturedRequest?.httpBody)
        XCTAssertEqual(
            try JSONDecoder().decode(OrderUpdateRequest.self, from: body),
            OrderUpdateRequest(isSealed: true))
        XCTAssertEqual(store.order?.isSealed, true)
    }
}
