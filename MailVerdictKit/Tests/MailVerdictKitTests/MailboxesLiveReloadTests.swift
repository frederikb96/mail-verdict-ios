import XCTest

@testable import MailVerdictKit

/// What the Mailboxes screen asks the server for when live events arrive: a burst during a sync
/// must cost one running reload and at most one queued, and an event re-reads only what it can
/// have changed.
@MainActor
final class MailboxesLiveReloadTests: XCTestCase {

    private let first = testUUID(1)
    private let second = testUUID(2)
    private let firstInbox = testUUID(11)
    private let secondInbox = testUUID(22)

    override func tearDown() {
        MVStubURLProtocol.reset()
        super.tearDown()
    }

    private func makeStore() -> MailboxesStore {
        let factory = try! MVRequestFactory(baseURL: "https://stub.example.com", authProvider: { .none })
        let client = MVApiClient(requestFactory: factory, urlSession: MVStubURLProtocol.makeSession())
        let suite = try! XCTUnwrap(UserDefaults(suiteName: "mailboxes-live-\(UUID())"))
        return MailboxesStore(
            apiClient: client, ledger: makeTestLedger(transport: client), uiState: MailboxesUIState(defaults: suite),
            diskCache: MailboxesDiskCache(
                directory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)),
            recentViews: MVRecentViewRecord(defaults: suite))
    }

    private func json(_ body: String, delay: TimeInterval = 0) -> MVStubURLProtocol.Stub {
        .init(statusCode: 200, headers: ["Content-Type": "application/json"], body: Data(body.utf8), delay: delay)
    }

    private func account(_ id: UUID, name: String) -> String {
        """
        {"id":"\(id)","name":"\(name)","imap_host":"imap.example.com","imap_port":993,"imap_user":"u",
         "state":"idle","created_at":"2026-01-01T00:00:00Z","updated_at":"2026-01-01T00:00:00Z"}
        """
    }

    private func folderOrder(inbox: UUID, unread: Int) -> String {
        """
        {"folders":[{"folder_id":"\(inbox)","imap_name":"INBOX","display_name":null,"special_use":"inbox",
         "is_visible":true,"unread_count":\(unread),"total_count":10,"kind":"imap"}]}
        """
    }

    private func stubServer(unread: Int, folderOrderDelay: TimeInterval = 0) {
        var stubs: [String: MVStubURLProtocol.Stub] = [
            "/api/accounts": json("[\(account(first, name: "Personal")),\(account(second, name: "Work"))]"),
            "/api/unified/folders": json("[]"),
            "/api/outbox": json("[]"),
            "/api/alerts/badge": json(#"{"count":0}"#),
        ]
        for (id, inbox) in [(first, firstInbox), (second, secondInbox)] {
            stubs["/api/accounts/\(id)/sync-status"] = json(
                #"{"account_id":"\#(id)","state":"idle","last_full_sync":"2026-01-01T00:00:00Z"}"#)
            stubs["/api/accounts/\(id)/folder-order"] = json(
                folderOrder(inbox: inbox, unread: unread), delay: folderOrderDelay)
        }
        MVStubURLProtocol.stubsByPath = stubs
    }

    private func requests(to suffix: String) -> Int {
        MVStubURLProtocol.capturedPaths.filter { $0.hasSuffix(suffix) }.count
    }

    private func unreadOfFirstInbox(_ store: MailboxesStore) -> Int? {
        store.accountSections.first { $0.id == first }?.folders.first?.badgeCount
    }

    /// A sync produces mail events in successive flush windows. Each used to start a full load of
    /// both accounts, their sync statuses and the rest, whether or not one was already running.
    func testEventsDuringAReloadQueueOneMoreNotOnePerEvent() async {
        stubServer(unread: 1, folderOrderDelay: 0.3)
        let store = makeStore()
        await store.load()
        let before = MVStubURLProtocol.capturedRequests.count
        let event = MVLiveInvalidation.mailNew(accountId: first, folderId: firstInbox, messageId: UUID())

        store.apply([event])
        await waitUntil { self.requests(to: "/\(self.first)/folder-order") == 2 }
        for _ in 0..<5 { store.apply([event]) }
        try? await Task.sleep(nanoseconds: 1_200_000_000)

        XCTAssertEqual(
            requests(to: "/\(first)/folder-order"), 3,
            "the load, the running reload, and one queued for the five that arrived meanwhile")
        XCTAssertEqual(
            MVStubURLProtocol.capturedRequests.count - before, 4, "a folder-order and the unified rows, twice")
    }

    /// A mail event moves counts only, so nothing else on the screen is read again — not the
    /// account list, the other account, any sync status, the dead outbox or the badge.
    func testAMailEventReadsOnlyTheCountsOfItsAccount() async {
        stubServer(unread: 1)
        let store = makeStore()
        await store.load()
        let before = MVStubURLProtocol.capturedRequests.count

        stubServer(unread: 7)
        store.apply([.mailUpdated(accountId: first, folderId: firstInbox, messageId: UUID(), changed: ["is_seen"])])
        await waitUntil { self.unreadOfFirstInbox(store) == 7 }

        try? await Task.sleep(nanoseconds: 200_000_000)
        let paths = MVStubURLProtocol.capturedPaths.dropFirst(before)
        XCTAssertEqual(Set(paths), ["/api/accounts/\(first)/folder-order", "/api/unified/folders"])
    }

    func testAFlagOnlyUpdateReadsNothing() async {
        stubServer(unread: 1)
        let store = makeStore()
        await store.load()
        let before = MVStubURLProtocol.capturedRequests.count

        store.apply([.mailUpdated(accountId: first, folderId: firstInbox, messageId: UUID(), changed: ["is_flagged"])])
        try? await Task.sleep(nanoseconds: 300_000_000)

        XCTAssertEqual(MVStubURLProtocol.capturedRequests.count, before)
    }

    /// The badge is alerts, and alert events say when they change; the dead banner follows the
    /// outbox. Each reads its own request.
    func testAlertAndOutboxEventsReadOnlyTheirOwnRequest() async {
        stubServer(unread: 1)
        let store = makeStore()
        await store.load()
        var before = MVStubURLProtocol.capturedRequests.count

        MVStubURLProtocol.stubsByPath["/api/alerts/badge"] = json(#"{"count":4}"#)
        store.apply([.alertsChanged])
        await waitUntil { store.bellBadgeCount == 4 }
        XCTAssertEqual(MVStubURLProtocol.capturedPaths.dropFirst(before).map { $0 }, ["/api/alerts/badge"])

        before = MVStubURLProtocol.capturedRequests.count
        store.apply([.outboxUpdated(MVOutboxEventPayload(id: UUID(), status: "dead"))])
        await waitUntil { MVStubURLProtocol.capturedRequests.count > before }
        try? await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(MVStubURLProtocol.capturedPaths.dropFirst(before).map { $0 }, ["/api/outbox"])
    }

    /// An event for an account the screen does not show (just added) cannot be answered from what
    /// is on screen, so the whole screen is read.
    func testAnEventForAnUnshownAccountFallsBackToAFullLoad() async {
        stubServer(unread: 1)
        let store = makeStore()
        await store.load()

        store.apply([.mailNew(accountId: testUUID(3), folderId: nil, messageId: UUID())])
        await waitUntil { self.requests(to: "/api/accounts") > 1 }
        try? await Task.sleep(nanoseconds: 500_000_000)
    }
}
