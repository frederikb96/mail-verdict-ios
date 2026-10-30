import XCTest

@testable import MailVerdictKit

#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif

/// The wallet through the stores: what the list asks the server for, what the detail does with a
/// ticket's code and added files, and what stands in when the server cannot be reached.
@MainActor
final class OrderWalletStoreTests: XCTestCase {

    override func tearDown() {
        MVStubURLProtocol.reset()
        super.tearDown()
    }

    private var client: MVApiClient {
        let factory = try! MVRequestFactory(baseURL: "https://stub.example.com", authProvider: { .none })
        return MVApiClient(requestFactory: factory, urlSession: MVStubURLProtocol.makeSession())
    }

    private func makeCache() -> MVOfflineCache {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("wallet-cache-\(UUID())")
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return MVOfflineCache(directory: directory)
    }

    private func defaults() -> UserDefaults {
        let suite = "OrderWalletStoreTests.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        return defaults
    }

    private func itemJSON(id: UUID, kind: String, day: String, updatedAt: String = "2026-04-23T10:00:00+00:00")
        -> String
    {
        """
        {"id":"\(id)","merchant":"Deutsche Bahn","subject":"Aachen to Berlin","status":"ticket issued",
        "title":"t","is_open":true,"is_favorite":false,"is_sealed":false,"open_set_by":"ai",
        "expected_until":null,"icon":"train","summary_preview":"p","kind":"\(kind)","kind_set_by":"ai",
        "event_start":"\(day)","event_end":null,"timeline_date":"\(day)",
        "first_mail_at":"2026-04-21T09:00:00+00:00","last_mail_at":"2026-04-23T10:00:00+00:00",
        "first_activity_at":"2026-04-21T09:00:00+00:00","last_activity_at":"2026-04-23T10:00:00+00:00",
        "mail_count":1,"file_count":0,"account_ids":[],"text_stale":false,"updated_at":"\(updatedAt)"}
        """
    }

    private func listBody(_ items: [String], hasMore: Bool = false) -> Data {
        Data("{\"items\":[\(items.joined(separator: ","))],\"has_more\":\(hasMore),\"next_cursor\":null}".utf8)
    }

    private func okList(_ items: [String]) -> MVStubURLProtocol.Stub {
        .init(statusCode: 200, headers: [:], body: listBody(items))
    }

    // MARK: - List requests and persistence

    func testTicketsAskForTheEventTimelineInOnePageAndEverythingElseForActivity() async {
        MVStubURLProtocol.stub = okList([])
        let store = OrderListStore(apiClient: client, view: OrderViewState(kind: .tickets, open: true))
        await store.load()
        let tickets = MVStubURLProtocol.capturedRequest?.url?.query ?? ""
        for part in ["kind=ticket", "sort=event", "limit=500", "state=open"] {
            XCTAssertTrue(tickets.contains(part), "\(part) missing from \(tickets)")
        }

        let orders = OrderListStore(apiClient: client, view: OrderViewState(kind: .orders, favorites: true))
        await orders.load()
        let query = MVStubURLProtocol.capturedRequest?.url?.query ?? ""
        for part in ["kind=order", "sort=activity", "limit=50", "favorites=true", "state=all"] {
            XCTAssertTrue(query.contains(part), "\(part) missing from \(query)")
        }
    }

    func testTheChosenViewIsRestoredByTheNextStoreAndLoadedFromTheFirstRequest() async {
        let persistence = OrderViewPersistence(defaults: defaults())
        MVStubURLProtocol.stub = okList([])
        let first = OrderListStore(apiClient: client, persistence: persistence)
        await first.setKind(.tickets)
        await first.toggleOpen()
        await first.toggleFavorites()

        let second = OrderListStore(apiClient: client, persistence: persistence)
        XCTAssertEqual(second.view, OrderViewState(kind: .tickets, open: true, favorites: true))
        await second.load()
        let query = MVStubURLProtocol.capturedRequest?.url?.query ?? ""
        XCTAssertTrue(query.contains("kind=ticket") && query.contains("state=open") && query.contains("favorites=true"))
    }

    func testChangingTheViewEmptiesTheRowsAtOnceAndAnAnswerForTheOldViewNeverLands() async throws {
        let ticket = UUID(), order = UUID()
        MVStubURLProtocol.queue = [
            .init(
                statusCode: 200, headers: [:],
                body: listBody([itemJSON(id: ticket, kind: "ticket", day: "2026-06-01")]), delay: 0.3),
            okList([itemJSON(id: order, kind: "order", day: "2026-05-01")]),
        ]
        let store = OrderListStore(apiClient: client)
        let slow = Task { await store.setKind(.tickets) }
        // Wait until the tickets request is in flight, so the next request is unambiguously second.
        while MVStubURLProtocol.capturedRequests.isEmpty { try await Task.sleep(for: .milliseconds(5)) }
        await store.setKind(.orders)
        XCTAssertEqual(store.rows.map(\.id), [order])
        await slow.value
        XCTAssertEqual(store.rows.map(\.id), [order], "the superseded tickets answer must not replace the orders")
        XCTAssertEqual(store.view.kind, .orders)
    }

    func testTheTimelineIsBuiltFromTheLoadedRowsAroundTheStoresToday() async {
        let past = UUID(), future = UUID()
        MVStubURLProtocol.stub = okList([
            itemJSON(id: past, kind: "ticket", day: "2026-04-01"),
            itemJSON(id: future, kind: "ticket", day: "2026-07-01"),
        ])
        let factory = try! MVRequestFactory(baseURL: "https://stub.example.com", authProvider: { .none })
        let api = MVApiClient(requestFactory: factory, urlSession: MVStubURLProtocol.makeSession())
        let store = OrderListStore(apiClient: api, view: OrderViewState(kind: .tickets), today: { "2026-05-10" })
        await store.load()
        XCTAssertEqual(store.timeline.entries.map(\.id), [future.uuidString, OrderTimeline.todayID, past.uuidString])
    }

    // MARK: - Offline

    func testTheTicketListFallsBackToItsSavedCopyWhenTheServerCannotBeReached() async throws {
        let cache = makeCache()
        let id = UUID()
        MVStubURLProtocol.stub = okList([itemJSON(id: id, kind: "ticket", day: "2026-06-01")])
        let online = OrderListStore(
            apiClient: client, view: OrderViewState(kind: .tickets), offlineCache: cache)
        await online.load()
        // The copy is written in the background after the answer.
        var saved: MVOfflineOrderList?
        for _ in 0..<200 where saved == nil {
            saved = await cache.orderList(key: OrderViewState(kind: .tickets).identity)
            if saved == nil { try await Task.sleep(for: .milliseconds(10)) }
        }
        XCTAssertNotNil(saved)

        MVStubURLProtocol.reset()
        MVStubURLProtocol.stub = .init(statusCode: 200, headers: [:], body: Data(), failure: .notConnectedToInternet)
        let offline = OrderListStore(
            apiClient: client, view: OrderViewState(kind: .tickets), offlineCache: cache)
        await offline.load()
        XCTAssertEqual(offline.rows.map(\.id), [id])
        XCTAssertNotNil(offline.savedCopyAt)
        XCTAssertNil(offline.errorMessage)
    }

    func testAServerRefusalIsNeverAnsweredWithTheSavedCopy() async throws {
        let cache = makeCache()
        await cache.saveOrderList(
            [
                OrderListItem(
                    id: UUID(), merchant: "m", subject: "s", status: "", title: "", isOpen: true, icon: "x",
                    summaryPreview: "", firstMailAt: nil, lastMailAt: nil, mailCount: 0, accountIds: [],
                    textStale: false,
                    updatedAt: Date())
            ], hasMore: false, key: OrderViewState().identity)
        MVStubURLProtocol.stub = .init(statusCode: 403, headers: [:], body: Data(#"{"detail":"no"}"#.utf8))
        let store = OrderListStore(apiClient: client, offlineCache: cache)
        await store.load()
        XCTAssertEqual(store.errorMessage, "no")
        XCTAssertTrue(store.rows.isEmpty)
        XCTAssertNil(store.savedCopyAt)
    }

    // MARK: - Detail

    private func detailJSON(
        id: UUID, factID: UUID = UUID(), documents: String = "[]", updatedAt: String = "2026-04-23T10:00:00+00:00"
    ) -> String {
        """
        {"id":"\(id)","merchant":"Deutsche Bahn","subject":"Aachen to Berlin","status":"ticket issued",
        "title":"t","is_open":true,"is_favorite":false,"is_sealed":false,"open_set_by":"ai",
        "expected_until":null,"icon":"train","summary_preview":"p","kind":"ticket","kind_set_by":"ai",
        "event_start":"2026-06-01","event_end":null,"timeline_date":"2026-06-01",
        "first_mail_at":null,"last_mail_at":null,"first_activity_at":null,"last_activity_at":null,
        "mail_count":1,"file_count":0,"account_ids":[],"text_stale":false,"updated_at":"\(updatedAt)",
        "summary":"s","facts":[
          {"id":"\(factID)","kind":"code","label":"Ticketcode","value":"","carrier":null,"tracking_url":null,
           "code":{"format":"Aztec","payload_text":null,"image_url":"/api/orders/\(id)/codes/\(factID).png","page":1},
           "document_id":null},
          {"id":"\(UUID())","kind":"tracking_number","label":"Tracking","value":"123","carrier":"dhl",
           "tracking_url":"https://dhl.example/t?n=123","code":null,"document_id":null}],
        "mails":[],"documents":\(documents)}
        """
    }

    private func detailStore(_ id: UUID, cache: MVOfflineCache? = nil) -> OrderDetailStore {
        OrderDetailStore(
            orderId: id, apiClient: client, offlineCache: cache, uploadPollInterval: .milliseconds(1),
            uploadPollLimit: 5)
    }

    func testTheDetailDecodesFactsWithTheirCodeAndTrackingLink() async throws {
        let id = UUID()
        MVStubURLProtocol.stub = .init(statusCode: 200, headers: [:], body: Data(detailJSON(id: id).utf8))
        let store = detailStore(id)
        await store.load()
        let order = try XCTUnwrap(store.order)
        XCTAssertEqual(order.kind, .ticket)
        XCTAssertEqual(order.timelineDate, "2026-06-01")
        XCTAssertEqual(order.codeFacts.count, 1)
        XCTAssertEqual(order.detailFacts.first?.linkURL?.host, "dhl.example")
    }

    func testACodeImageIsFetchedOnceAndThenServedFromTheSavedCopy() async throws {
        let id = UUID(), factID = UUID()
        let cache = makeCache()
        MVStubURLProtocol.queue = [
            .init(statusCode: 200, headers: [:], body: Data(detailJSON(id: id, factID: factID).utf8))
        ]
        MVStubURLProtocol.stub = .init(statusCode: 200, headers: ["Content-Type": "image/png"], body: Data([1, 2, 3]))
        let store = detailStore(id, cache: cache)
        await store.load()
        let fact = try XCTUnwrap(store.order?.codeFacts.first)

        let first = await store.codeImage(for: fact)
        XCTAssertEqual(first, Data([1, 2, 3]))
        let imageRequests = MVStubURLProtocol.capturedRequests.filter { $0.url?.path.hasSuffix(".png") == true }
        XCTAssertEqual(imageRequests.first?.url?.query, "scale=8")

        let before = MVStubURLProtocol.capturedRequests.count
        MVStubURLProtocol.stub = .init(statusCode: 200, headers: [:], body: Data(), failure: .notConnectedToInternet)
        let again = await store.codeImage(for: fact)
        XCTAssertEqual(again, Data([1, 2, 3]))
        XCTAssertEqual(MVStubURLProtocol.capturedRequests.count, before, "a saved code needs no request")
    }

    func testATicketOpensOfflineFromItsSavedDetailAndCode() async throws {
        let id = UUID(), factID = UUID()
        let cache = makeCache()
        MVStubURLProtocol.queue = [
            .init(statusCode: 200, headers: [:], body: Data(detailJSON(id: id, factID: factID).utf8))
        ]
        MVStubURLProtocol.stub = .init(statusCode: 200, headers: ["Content-Type": "image/png"], body: Data([9, 9]))
        let online = detailStore(id, cache: cache)
        await online.load()
        // The detail and its code image are written in the background after the answer.
        var png: Data?
        for _ in 0..<200 where png == nil {
            png = await cache.orderCode(factId: factID)
            if png == nil { try await Task.sleep(for: .milliseconds(10)) }
        }
        XCTAssertEqual(png, Data([9, 9]))

        MVStubURLProtocol.reset()
        MVStubURLProtocol.stub = .init(statusCode: 200, headers: [:], body: Data(), failure: .notConnectedToInternet)
        let offline = detailStore(id, cache: cache)
        await offline.load()
        XCTAssertEqual(offline.order?.id, id)
        XCTAssertNotNil(offline.savedCopyAt)
        XCTAssertNil(offline.errorMessage)
        let fact = try XCTUnwrap(offline.order?.codeFacts.first)
        let shown = await offline.codeImage(for: fact)
        XCTAssertEqual(shown, Data([9, 9]))
    }

    func testARefreshThatFailsLeavesTheTicketOnScreen() async {
        let id = UUID()
        MVStubURLProtocol.stub = .init(statusCode: 200, headers: [:], body: Data(detailJSON(id: id).utf8))
        let store = detailStore(id)
        await store.load()
        MVStubURLProtocol.stub = .init(statusCode: 200, headers: [:], body: Data(), failure: .notConnectedToInternet)
        await store.load()
        XCTAssertEqual(store.order?.id, id)
        XCTAssertNil(store.errorMessage)
    }

    func testAnOrderWithNoSavedCopyShowsTheErrorWhenOffline() async {
        let id = UUID()
        MVStubURLProtocol.stub = .init(statusCode: 200, headers: [:], body: Data(), failure: .notConnectedToInternet)
        let store = detailStore(id, cache: makeCache())
        await store.load()
        XCTAssertNil(store.order)
        XCTAssertNotNil(store.errorMessage)
    }

    func testOnlyACodeFactCanBePresentedFullscreen() async throws {
        let id = UUID()
        MVStubURLProtocol.stub = .init(statusCode: 200, headers: [:], body: Data(detailJSON(id: id).utf8))
        let store = detailStore(id)
        await store.load()
        let order = try XCTUnwrap(store.order)
        store.presentCode(order.detailFacts[0])
        XCTAssertNil(store.presentedCodeFactId)
        store.presentCode(order.codeFacts[0])
        XCTAssertEqual(store.presentedCodeFactId, order.codeFacts[0].id)
    }

    // MARK: - Adding a file

    private func status(_ file: UUID, _ status: String, order: UUID?, error: String? = nil) -> MVStubURLProtocol.Stub {
        let orderField = order.map { "\"\($0)\"" } ?? "null"
        let errorField = error.map { "\"\($0)\"" } ?? "null"
        return .init(
            statusCode: 200, headers: [:],
            body: Data(
                "{\"file_id\":\"\(file)\",\"order_id\":\(orderField),\"status\":\"\(status)\",\"last_error\":\(errorField)}"
                    .utf8))
    }

    func testAddingAFileSendsItWithTheOrderThenPollsUntilAttachedAndReadsTheOrderAgain() async throws {
        let id = UUID(), file = UUID()
        MVStubURLProtocol.queue = [
            .init(statusCode: 200, headers: [:], body: Data(detailJSON(id: id).utf8)),
            status(file, "pending", order: nil),
            status(file, "pending", order: nil),
            status(file, "attached", order: id),
            .init(statusCode: 200, headers: [:], body: Data(detailJSON(id: id).utf8)),
        ]
        let store = detailStore(id)
        await store.load()
        await store.addFile(data: Data("%PDF-1.4".utf8), filename: "ticket.pdf", contentType: "application/pdf")

        let requests = MVStubURLProtocol.capturedRequests
        XCTAssertEqual(
            requests.map { "\($0.httpMethod ?? "") \($0.url?.path ?? "")" },
            [
                "GET /api/orders/\(id)", "POST /api/orders/files", "GET /api/orders/files/\(file)",
                "GET /api/orders/files/\(file)", "GET /api/orders/\(id)",
            ])
        let upload = requests[1]
        XCTAssertTrue(
            upload.value(forHTTPHeaderField: "Content-Type")?.hasPrefix("multipart/form-data; boundary=") == true)
        let body = String(decoding: upload.httpBody ?? upload.httpBodyStreamData(), as: UTF8.self)
        XCTAssertTrue(body.contains("name=\"file\"; filename=\"ticket.pdf\""))
        XCTAssertTrue(body.contains("Content-Type: application/pdf"))
        XCTAssertTrue(body.contains("name=\"order_id\"\r\n\r\n\(id.uuidString)\r\n"))
        XCTAssertTrue(store.uploads.isEmpty)
    }

    func testAFileTheServerRefusesStaysListedWithTheServersReason() async throws {
        let id = UUID()
        MVStubURLProtocol.stub = .init(
            statusCode: 415, headers: [:], body: Data(#"{"detail":"This file type is not accepted."}"#.utf8))
        let store = detailStore(id)
        await store.addFile(data: Data([1]), filename: "photo.heic", contentType: "image/heic")
        XCTAssertEqual(store.uploads.map(\.state), [.failed("This file type is not accepted.")])
        store.dismissUpload(store.uploads[0].id)
        XCTAssertTrue(store.uploads.isEmpty)
    }

    func testAFileThatFailsPlacementShowsTheReasonTheServerGave() async throws {
        let id = UUID(), file = UUID()
        MVStubURLProtocol.queue = [
            status(file, "pending", order: nil), status(file, "failed", order: nil, error: "Could not be read"),
        ]
        let store = detailStore(id)
        await store.addFile(data: Data([1]), filename: "scan.png", contentType: "image/png")
        XCTAssertEqual(store.uploads.map(\.state), [.failed("Could not be read")])
    }

    func testAFileStillPendingAfterTheWaitIsReportedNotDropped() async throws {
        let id = UUID(), file = UUID()
        MVStubURLProtocol.stub = status(file, "pending", order: nil)
        let store = detailStore(id)
        await store.addFile(data: Data([1]), filename: "scan.png", contentType: "image/png")
        guard case .failed(let message)? = store.uploads.first?.state else {
            return XCTFail("expected a failed entry, got \(store.uploads)")
        }
        XCTAssertTrue(message.contains("longer than usual"))
    }

    // MARK: - Documents and kind

    func testAnyDocumentDownloadsFromItsOwnPathAndAGoneOneIsRefused() async throws {
        let id = UUID()
        let store = detailStore(id)
        MVStubURLProtocol.stub = .init(statusCode: 200, headers: [:], body: Data("bytes".utf8))
        let file = OrderDocumentOut(
            id: UUID(), source: "file", messageId: nil, attachmentId: nil, fileId: UUID(), filename: "a.pdf",
            contentType: "application/pdf", sizeBytes: 5, receivedAt: Date(),
            downloadUrl: "/api/orders/\(id)/files/abc")
        let data = try await store.downloadDocument(file)
        XCTAssertEqual(String(decoding: data, as: UTF8.self), "bytes")
        XCTAssertEqual(MVStubURLProtocol.capturedRequest?.url?.path, "/api/orders/\(id)/files/abc")

        let gone = OrderDocumentOut(
            id: UUID(), source: "mail", messageId: nil, attachmentId: nil, fileId: nil, filename: "b.pdf",
            contentType: "application/pdf", sizeBytes: nil, receivedAt: Date(), downloadUrl: nil)
        do {
            _ = try await store.downloadDocument(gone)
            XCTFail("expected a refusal")
        } catch {
            XCTAssertTrue(error.mvIsNotFound)
        }
    }

    func testChangingTheKindPatchesOnlyTheKind() async throws {
        let id = UUID()
        MVStubURLProtocol.stub = .init(statusCode: 200, headers: [:], body: Data(detailJSON(id: id).utf8))
        let store = detailStore(id)
        await store.load()
        try await store.setKind(.other)
        let body = try XCTUnwrap(MVStubURLProtocol.capturedRequest?.httpBody)
        XCTAssertEqual(MVStubURLProtocol.capturedRequest?.httpMethod, "PATCH")
        XCTAssertEqual(try JSONDecoder().decode(OrderUpdateRequest.self, from: body), OrderUpdateRequest(kind: .other))
    }
}

extension URLRequest {
    /// `URLSession` hands a protocol the body as a stream once it is large enough; the stub reads it back.
    fileprivate func httpBodyStreamData() -> Data {
        guard let stream = httpBodyStream else { return Data() }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            if count <= 0 { break }
            data.append(buffer, count: count)
        }
        return data
    }
}
