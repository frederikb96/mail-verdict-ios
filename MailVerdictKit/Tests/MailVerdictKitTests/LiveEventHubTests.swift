import XCTest
@testable import MailVerdictKit

/// Every row of the UX design's event table (§2.0, amended by the calendar-invitation addendum)
/// gets its own mapping test here — `LiveEventHub.mapRecord` is `nonisolated` precisely so these
/// can call it directly, with no actor hop and no SSE transport involved.
final class LiveEventHubMappingTests: XCTestCase {

    private func record(_ name: String, _ json: String = "{}", id: String? = nil) -> MVSseRecord {
        MVSseRecord(id: id, name: name, data: json)
    }

    func testConnectedIsIgnored() {
        XCTAssertEqual(
            LiveEventHub.mapRecord(record("connected")), .ignored(.connected)
        )
    }

    func testResyncInvalidatesEverything() {
        XCTAssertEqual(LiveEventHub.mapRecord(record("resync")), .resync)
    }

    func testMailNewCarriesAccountFolderAndMessageIds() {
        let accountId = UUID(), folderId = UUID(), messageId = UUID()
        let json = """
            {"id":"\(messageId)","account_id":"\(accountId)","folder_id":"\(folderId)"}
            """
        XCTAssertEqual(
            LiveEventHub.mapRecord(record("mail.new", json)),
            .mailNew(accountId: accountId, folderId: folderId, messageId: messageId)
        )
    }

    func testMailUpdatedCarriesTheChangedFieldList() {
        let messageId = UUID()
        let json = "{\"id\":\"\(messageId)\",\"changed\":[\"folder_id\",\"is_seen\"]}"
        XCTAssertEqual(
            LiveEventHub.mapRecord(record("mail.updated", json)),
            .mailUpdated(accountId: nil, folderId: nil, messageId: messageId, changed: ["folder_id", "is_seen"])
        )
    }

    func testMailDeletedCarriesTheMessageId() {
        let messageId = UUID()
        XCTAssertEqual(
            LiveEventHub.mapRecord(record("mail.deleted", "{\"id\":\"\(messageId)\"}")),
            .mailDeleted(accountId: nil, folderId: nil, messageId: messageId)
        )
    }

    func testVerdictIssuedCarriesIsSpam() {
        let messageId = UUID()
        let json = "{\"message_id\":\"\(messageId)\",\"is_spam\":true}"
        XCTAssertEqual(
            LiveEventHub.mapRecord(record("verdict.issued", json)),
            .verdictIssued(accountId: nil, messageId: messageId, isSpam: true)
        )
    }

    func testAlertNewAndAlertDismissedBothInvalidateAlerts() {
        XCTAssertEqual(LiveEventHub.mapRecord(record("alert.new")), .alertsChanged)
        XCTAssertEqual(LiveEventHub.mapRecord(record("alert.dismissed")), .alertsChanged)
    }

    func testNotificationNewInvalidatesNotifications() {
        XCTAssertEqual(LiveEventHub.mapRecord(record("notification.new")), .notificationsChanged)
    }

    func testAccountChangedInvalidatesAccounts() {
        XCTAssertEqual(LiveEventHub.mapRecord(record("account.changed")), .accountsChanged)
    }

    func testFolderSyncedCarriesTheFolderId() {
        let folderId = UUID()
        XCTAssertEqual(
            LiveEventHub.mapRecord(record("folder.synced", "{\"folder_id\":\"\(folderId)\",\"backfill\":false}")),
            .folderSynced(accountId: nil, folderId: folderId)
        )
    }

    func testFolderChangedInvalidatesFolders() {
        XCTAssertEqual(LiveEventHub.mapRecord(record("folder.changed")), .foldersChanged)
    }

    func testOutboxUpdatedCarriesStatusAndKind() {
        let id = UUID()
        let json = "{\"id\":\"\(id)\",\"changed\":[],\"status\":\"sent\",\"kind\":\"send\"}"
        XCTAssertEqual(
            LiveEventHub.mapRecord(record("outbox.updated", json)),
            .outboxUpdated(MVOutboxEventPayload(id: id, changed: [], status: "sent", kind: "send"))
        )
    }

    /// The addendum's own amendment: an `itip: "reply"` outbox row is never the ordinary
    /// `.outboxUpdated` case — no mail toast, no list refresh, only the invitation card.
    func testOutboxUpdatedWithItipReplyBecomesInvitationOrEventChanged() {
        let json = "{\"id\":\"\(UUID())\",\"itip\":\"reply\"}"
        XCTAssertEqual(LiveEventHub.mapRecord(record("outbox.updated", json)), .invitationOrEventChanged)
    }

    func testSettingsChangedCarriesTheCategory() {
        XCTAssertEqual(
            LiveEventHub.mapRecord(record("settings.changed", "{\"category\":\"mail\"}")),
            .settingsChanged(category: "mail")
        )
    }

    func testSettingsChangedWithNoCategoryMeansSeveral() {
        XCTAssertEqual(LiveEventHub.mapRecord(record("settings.changed")), .settingsChanged(category: nil))
    }

    func testIdentityChangedCarriesTheAccountId() {
        let accountId = UUID()
        XCTAssertEqual(
            LiveEventHub.mapRecord(record("identity.changed", "{\"account_id\":\"\(accountId)\"}")),
            .identitiesChanged(accountId: accountId)
        )
    }

    func testCalendarObjectInvalidatesTheInvitationCard() {
        XCTAssertEqual(LiveEventHub.mapRecord(record("calendar.object")), .invitationOrEventChanged)
    }

    func testEveryOtherCalendarAndContactEventIsIgnored() {
        for name: SSEEventName in [
            .calendarAccount, .calendarCollection, .calendarLinksChanged, .contactCollection, .contactObject,
        ] {
            XCTAssertEqual(LiveEventHub.mapRecord(record(name.rawValue)), .ignored(name))
        }
    }

    func testEveryPipelineEventIsIgnored() {
        for name: SSEEventName in [.pipelineDocumentChanged, .pipelineNotify, .pipelineRunFinished] {
            XCTAssertEqual(LiveEventHub.mapRecord(record(name.rawValue)), .ignored(name))
        }
    }

    func testAnUnrecognizedEventNameIsNeverSilentlyDropped() {
        XCTAssertEqual(LiveEventHub.mapRecord(record("some.future.event")), .unknown("some.future.event"))
    }

    /// Every `SSEEventName` case has a row above — if this fails, a case was added to the enum
    /// without a matching mapping test, which is exactly the coverage gap this file exists to
    /// prevent.
    func testEverySSEEventNameCaseHasAMappingTestAbove() {
        let covered: Set<String> = [
            "connected", "resync", "mail.new", "mail.updated", "mail.deleted", "verdict.issued",
            "alert.new", "alert.dismissed", "notification.new", "account.changed", "folder.synced",
            "folder.changed", "outbox.updated", "settings.changed", "identity.changed",
            "calendar.account", "calendar.collection", "calendar.links_changed", "calendar.object",
            "contact.collection", "contact.object", "pipeline.document_changed", "pipeline.notify",
            "pipeline.run_finished",
        ]
        XCTAssertEqual(covered, Set(SSEEventName.allCases.map(\.rawValue)))
    }
}

/// The coalescing behaviour itself — separate from the pure mapping above, since it needs the
/// actual `LiveEventHub` instance and its timer. `@MainActor` because `LiveEventHub` itself is;
/// every test method below is `async`, which is required here — a `@MainActor XCTestCase` with
/// only synchronous test methods crashes at runtime on Linux.
@MainActor
final class LiveEventHubBufferingTests: XCTestCase {

    override func tearDown() {
        MVStubURLProtocol.reset()
        super.tearDown()
    }

    private func makeHub() throws -> LiveEventHub {
        let factory = try MVRequestFactory(baseURL: "https://stub.example.com", authProvider: { .none })
        return LiveEventHub(requestFactory: factory, urlSessionConfiguration: MVStubURLProtocol.makeConfiguration())
    }

    /// Several `mail.new` records arriving faster than the 500 ms flush interval reach the
    /// subscriber as one batch, not one delivery per record.
    func testBurstsOfMailEventsAreCoalescedIntoOneBatch() async throws {
        let raw =
            "event: mail.new\r\ndata: {\"id\":\"\(UUID())\"}\r\n\r\n"
            + "event: mail.new\r\ndata: {\"id\":\"\(UUID())\"}\r\n\r\n"
            + "event: mail.new\r\ndata: {\"id\":\"\(UUID())\"}\r\n\r\n"
        MVStubURLProtocol.stub = .init(statusCode: 200, headers: [:], body: Data(raw.utf8))

        let signal = MVStreamConnectionSignal()
        let subscriber = MockSubscriber { Task { await signal.fire() } }
        let hub = try makeHub()
        hub.subscribe(subscriber)
        hub.connect()
        await signal.wait()

        XCTAssertEqual(subscriber.batches.count, 1)
        XCTAssertEqual(subscriber.batches.first?.count, 3)
    }

    /// A non-mail event (here, `account.changed`) is never held for the next flush tick.
    func testNonMailEventsAreDeliveredImmediately() async throws {
        let raw = "event: account.changed\r\ndata: {}\r\n\r\n"
        MVStubURLProtocol.stub = .init(statusCode: 200, headers: [:], body: Data(raw.utf8))

        let signal = MVStreamConnectionSignal()
        let subscriber = MockSubscriber { Task { await signal.fire() } }
        let hub = try makeHub()
        hub.subscribe(subscriber)
        hub.connect()
        await signal.wait()

        XCTAssertEqual(subscriber.batches.first?.first, .accountsChanged)
    }

    /// Every subscribed store hears the same event — one SSE connection, fanned out.
    func testEveryRegisteredSubscriberReceivesTheSameBatch() async throws {
        let raw = "event: account.changed\r\ndata: {}\r\n\r\n"
        MVStubURLProtocol.stub = .init(statusCode: 200, headers: [:], body: Data(raw.utf8))

        let signal = MVStreamConnectionSignal()
        let first = MockSubscriber()
        let second = MockSubscriber { Task { await signal.fire() } }
        let hub = try makeHub()
        hub.subscribe(first)
        hub.subscribe(second)
        hub.connect()
        await signal.wait()

        XCTAssertEqual(first.batches.first, [.accountsChanged])
        XCTAssertEqual(second.batches.first, [.accountsChanged])
    }

    /// `unsubscribe` is what it says — no further delivery, immediately.
    func testUnsubscribingStopsFurtherDelivery() async throws {
        let raw = "event: account.changed\r\ndata: {}\r\n\r\n"
        MVStubURLProtocol.stub = .init(statusCode: 200, headers: [:], body: Data(raw.utf8))

        let signal = MVStreamConnectionSignal()
        let watcher = MockSubscriber { Task { await signal.fire() } }
        let subscriber = MockSubscriber()
        let hub = try makeHub()
        let token = hub.subscribe(subscriber)
        hub.subscribe(watcher)
        hub.unsubscribe(token)
        hub.connect()
        await signal.wait()

        XCTAssertTrue(subscriber.batches.isEmpty)
    }

    /// A subscriber joining after the hub is already connected is told so immediately, rather
    /// than sitting as "offline" until the next state change. The stub's stream ends (and the
    /// hub starts reconnecting) the instant it finishes delivering its empty body, so the late
    /// subscribe has to happen inside the same synchronous broadcast that reports `.connected` —
    /// anything that first returns to the test function risks racing the hub's own disconnect.
    func testSubscribingAfterConnectionIsUpReportsConnectedRightAway() async throws {
        MVStubURLProtocol.stub = .init(statusCode: 200, headers: [:], body: Data())
        let signal = MVStreamConnectionSignal()
        let hub = try makeHub()
        var lateSubscriberStates: [Bool] = []

        let connector = MockSubscriber(onSetConnected: { connected in
            guard connected else { return }
            let lateSubscriber = MockSubscriber()
            hub.subscribe(lateSubscriber)
            lateSubscriberStates = lateSubscriber.connectedStates
            Task { await signal.fire() }
        })
        hub.subscribe(connector)
        hub.connect()
        await signal.wait()

        XCTAssertEqual(lateSubscriberStates, [true])
    }
}

@MainActor
private final class MockSubscriber: LiveEventSubscriber {
    private(set) var batches: [[MVLiveInvalidation]] = []
    private(set) var connectedStates: [Bool] = []
    private let onApply: (() -> Void)?
    private let onSetConnected: ((Bool) -> Void)?

    init(onApply: (() -> Void)? = nil, onSetConnected: ((Bool) -> Void)? = nil) {
        self.onApply = onApply
        self.onSetConnected = onSetConnected
    }

    func apply(_ invalidations: [MVLiveInvalidation]) {
        batches.append(invalidations)
        onApply?()
    }

    func setConnected(_ connected: Bool) {
        connectedStates.append(connected)
        onSetConnected?(connected)
    }
}
