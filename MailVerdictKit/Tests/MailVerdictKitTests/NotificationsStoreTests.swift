import XCTest
@testable import MailVerdictKit

@MainActor
final class NotificationsStoreTests: XCTestCase {

    override func tearDown() {
        MVStubURLProtocol.reset()
        super.tearDown()
    }

    private func makeStore() -> NotificationsStore {
        let factory = try! MVRequestFactory(baseURL: "https://stub.example.com", authProvider: { .none })
        let client = MVApiClient(requestFactory: factory, urlSession: MVStubURLProtocol.makeSession())
        return NotificationsStore(apiClient: client)
    }

    private func alertJSON(id: UUID, kind: String) -> String {
        """
        {"id":"\(id)","kind":"\(kind)","title":"Hi","body":null,"url":null,"account_id":null,
        "message_id":null,"folder_id":null,"delivered_at":null,"dismissed_at":null,
        "created_at":"2026-01-01T00:00:00+00:00"}
        """
    }

    private func notificationJSON(id: Int, accountId: UUID, action: String = "move") -> String {
        """
        {"id":\(id),"account_id":"\(accountId)","action":"\(action)","message_id":null,"folder_id":null,
        "outbox_id":null,"error":"it failed","detail":null,"acknowledged_at":null,"reverted_at":null,
        "created_at":"2026-01-01T00:00:00+00:00"}
        """
    }

    func testLoadSplitsAlertsIntoMailAndSystemTabs() async {
        let mailId = UUID(), reminderId = UUID()
        MVStubURLProtocol.stub = .init(
            statusCode: 200, headers: [:],
            body: Data("[\(alertJSON(id: mailId, kind: "mail")),\(alertJSON(id: reminderId, kind: "reminder"))]".utf8))

        let store = makeStore()
        await store.load()

        XCTAssertEqual(store.mailAlerts.map(\.id), [mailId])
        XCTAssertEqual(store.systemAlerts.map(\.id), [reminderId])
        XCTAssertEqual(store.systemAlertKinds, ["reminder"])
    }

    func testOneEndpointFailingLeavesTheOtherTabIntact() async {
        let accountId = UUID()
        MVStubURLProtocol.stub = .init(
            statusCode: 200, headers: [:], body: Data("[\(notificationJSON(id: 1, accountId: accountId))]".utf8))

        let store = makeStore()
        // Both endpoints answer the same stub here — the notifications array decodes fine, the
        // alerts array does not (different shape), so the alerts tab fails while notifications
        // still populate.
        await store.load()

        XCTAssertEqual(store.mailAlerts, [])
        XCTAssertEqual(store.notifications.map(\.id), [1])
        XCTAssertNotNil(store.errorMessage)
    }

    func testDismissAlertRemovesItFromWhicheverTabItWasIn() async {
        let mailId = UUID()
        MVStubURLProtocol.stub = .init(
            statusCode: 200, headers: [:], body: Data("[\(alertJSON(id: mailId, kind: "mail"))]".utf8))
        let store = makeStore()
        await store.load()
        XCTAssertEqual(store.mailAlerts.count, 1)

        MVStubURLProtocol.stub = .init(statusCode: 204, headers: [:], body: Data())
        await store.dismissAlert(mailId)
        XCTAssertEqual(store.mailAlerts, [])
    }

    func testAcknowledgeNotificationRemovesOnlyThatRow() async {
        let accountId = UUID()
        MVStubURLProtocol.stub = .init(
            statusCode: 200, headers: [:],
            body: Data(
                "[\(notificationJSON(id: 1, accountId: accountId)),\(notificationJSON(id: 2, accountId: accountId))]"
                    .utf8))
        let store = makeStore()
        await store.load()
        XCTAssertEqual(store.notifications.count, 2)

        MVStubURLProtocol.stub = .init(statusCode: 204, headers: [:], body: Data())
        await store.acknowledgeNotification(accountId: accountId, notificationId: 1)
        XCTAssertEqual(store.notifications.map(\.id), [2])
    }
}
