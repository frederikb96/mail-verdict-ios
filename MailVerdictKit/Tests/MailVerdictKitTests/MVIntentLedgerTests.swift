import XCTest

@testable import MailVerdictKit

/// A transport that records every delivery and answers each from a handler a test sets — per
/// message, so a test can fail one message and let another through.
final class RecordingIntentTransport: MVIntentTransport, @unchecked Sendable {
    typealias Handler = @Sendable (_ call: String) async throws -> Void

    private let lock = NSLock()
    private var _calls: [String] = []
    private var _keys: [UUID?] = []
    private var _timeouts: [TimeInterval] = []
    private var _inFlight = 0
    private var _maxInFlight = 0
    private var _handler: Handler = { _ in }
    private var _thread = ThreadResponse(messages: [])
    private var _threadFetches = 0
    private var _bulkIds: [[UUID]] = []

    private func locked<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }

    /// `"<action> <first message id's last digits>"`, in delivery order — `"archive 1"`.
    var calls: [String] { locked { _calls } }
    /// The idempotency key each delivery carried.
    var keys: [UUID?] { locked { _keys } }
    var timeouts: [TimeInterval] { locked { _timeouts } }
    var maxInFlight: Int { locked { _maxInFlight } }
    var thread: ThreadResponse {
        get { locked { _thread } }
        set { locked { _thread = newValue } }
    }
    var threadFetches: Int { locked { _threadFetches } }
    /// The ids each bulk delivery named.
    var bulkIds: [[UUID]] { locked { _bulkIds } }
    var handler: Handler {
        get { locked { _handler } }
        set { locked { _handler = newValue } }
    }

    static func label(_ action: String, _ id: UUID?) -> String {
        "\(action) \(id.map { String(Int($0.uuidString.suffix(12)) ?? -1) } ?? "-")"
    }

    private func record(_ call: String, key: UUID?, timeout: TimeInterval) async throws {
        let handler = locked {
            _calls.append(call)
            _keys.append(key)
            _timeouts.append(timeout)
            _inFlight += 1
            _maxInFlight = max(_maxInFlight, _inFlight)
            return _handler
        }
        defer { locked { _inFlight -= 1 } }
        try await handler(call)
    }

    func deliverMessageAction(
        messageId: UUID, action: MVMessageAction, targetFolderId: UUID?, expectedFolderId: UUID?, idempotencyKey: UUID,
        timeout: TimeInterval
    ) async throws -> MessageActionResponse {
        locked { _expected.append(expectedFolderId.map { [messageId: $0] } ?? [:]) }
        try await record(Self.label(action.rawValue, messageId), key: idempotencyKey, timeout: timeout)
        let (applied, filed) = locked { (_applied, _filedFolder) }
        return MessageActionResponse(
            success: messageResponseSuccess, action: action.rawValue, messageId: messageId,
            message: messageResponseSuccess ? nil : "Feedback processing failed", applied: applied, folderId: filed)
    }

    /// The folders each delivery expected its messages in.
    var expected: [[UUID: UUID]] { locked { _expected } }
    private var _expected: [[UUID: UUID]] = []
    /// What a single action answers: whether it applied, and where it filed the message.
    var applied: Bool {
        get { locked { _applied } }
        set { locked { _applied = newValue } }
    }
    private var _applied = true
    var filedFolder: UUID? {
        get { locked { _filedFolder } }
        set { locked { _filedFolder = newValue } }
    }
    private var _filedFolder: UUID?
    /// Bulk requests as sent.
    var bulkRequests: [BulkActionRequest] { locked { _bulkRequests } }
    private var _bulkRequests: [BulkActionRequest] = []

    func deliverBulkAction(
        accountId: UUID, request: BulkActionRequest, timeout: TimeInterval
    ) async throws -> BulkActionResponse {
        locked {
            _bulkIds.append(request.ids ?? [])
            _bulkRequests.append(request)
        }
        try await record(
            Self.label(request.action.rawValue, request.ids?.first), key: request.idempotencyKey, timeout: timeout)
        return BulkActionResponse(
            success: true, action: request.action.rawValue, affectedCount: request.ids?.count ?? 0)
    }

    func fetchConversation(messageId: UUID, timeout: TimeInterval) async throws -> ThreadResponse {
        locked {
            _threadFetches += 1
            _timeouts.append(timeout)
            return _thread
        }
    }

    /// What `fetchMessageState` answers per message; a message absent here is gone.
    var states: [UUID: MVMessageState] {
        get { locked { _states } }
        set { locked { _states = newValue } }
    }
    private var _states: [UUID: MVMessageState] = [:]
    /// Every state lookup, as `"state <n>"`, in order.
    var lookups: [String] { locked { _lookups } }
    private var _lookups: [String] = []
    var messageResponseSuccess: Bool {
        get { locked { _messageResponseSuccess } }
        set { locked { _messageResponseSuccess = newValue } }
    }
    private var _messageResponseSuccess = true

    /// The account's folders; the role folders by default, empty to model an account without them.
    var folders: [FolderResponse] {
        get { locked { _folders } }
        set { locked { _folders = newValue } }
    }
    private var _folders = testRoleFolderList()

    func fetchFolders(accountId: UUID, timeout: TimeInterval) async throws -> [FolderResponse] {
        locked { _folders }
    }

    func fetchMessageState(messageId: UUID, includeFlags: Bool, timeout: TimeInterval) async throws -> MVMessageState? {
        locked {
            _lookups.append(Self.label("state", messageId))
            return _states[messageId]
        }
    }
}

@MainActor
final class MVIntentLedgerTests: XCTestCase {
    private func request(_ action: MVBulkAction, _ n: Int, target: UUID? = nil) -> MVIntentRequest {
        MVIntentRequest(
            accountId: testAccount, action: action, targetFolderId: target, messageIds: [testUUID(n)],
            originFolderIds: [testUUID(n): testFolder], snapshots: [testRow(n)])
    }

    private func refusal(_ status: Int) -> MVError {
        MVError.detail("refused \(status)", statusCode: status)
    }

    // MARK: - Delivery order

    func testDeliversOneAtATimeInTheOrderTheActionsWereTaken() async {
        let gate = TestGate()
        let transport = RecordingIntentTransport()
        transport.handler = { _ in await gate.wait() }
        let ledger = makeTestLedger(transport: transport)

        ledger.enqueue(request(.markRead, 1))
        ledger.enqueue(request(.archive, 1))
        ledger.enqueue(request(.flag, 2))
        await waitUntil { transport.calls.count == 1 }
        await gate.open()
        await waitUntil { ledger.intents.allSatisfy { $0.state == .done } }

        XCTAssertEqual(transport.calls, ["mark_read 1", "archive 1", "flag 2"])
        XCTAssertEqual(transport.maxInFlight, 1)
        XCTAssertEqual(Set(transport.keys).count, 3, "two intents shared an idempotency key")
        XCTAssertEqual(transport.timeouts, Array(repeating: MVIntentLedger.Timing().requestTimeout, count: 3))
    }

    /// A message whose request is backing off holds back later intents for the same message — a
    /// mark-read and an archive never swap — while other messages go on.
    func testARetryHoldsBackTheSameMessageButNotOthers() async {
        let clock = TestIntentClock()
        let transport = RecordingIntentTransport()
        let failures = CallCounter()
        transport.handler = { call in
            if call == "mark_read 1", failures.next() == 1 { throw MVError.detail("slow down", statusCode: 429) }
        }
        let ledger = makeTestLedger(transport: transport, clock: clock)

        ledger.enqueue(request(.markRead, 1))
        ledger.enqueue(request(.archive, 1))
        ledger.enqueue(request(.flag, 2))
        let retryAt = clock.now.addingTimeInterval(1)
        await waitUntil { transport.calls == ["mark_read 1", "flag 2"] && clock.hasSleeper(endingAt: retryAt) }
        XCTAssertEqual(ledger.intents.map(\.state), [.pending, .pending, .done])

        clock.advance(by: 1)
        await waitUntil { transport.calls.count == 4 }

        XCTAssertEqual(transport.calls, ["mark_read 1", "flag 2", "mark_read 1", "archive 1"])
    }

    func testRetriesBackOffExponentiallyAndShowAsWaiting() async {
        let clock = TestIntentClock()
        let transport = RecordingIntentTransport()
        transport.handler = { _ in throw MVError.http(statusCode: 429, reason: "Too Many Requests") }
        let ledger = makeTestLedger(transport: transport, clock: clock)

        let id = ledger.enqueue(request(.archive, 1))
        var delays: [TimeInterval] = []
        for attempt in 1...4 {
            await waitUntil { transport.calls.count == attempt && ledger.intents.first?.state == .pending }
            let due = ledger.intents.first?.nextAttemptAt ?? clock.now
            delays.append(due.timeIntervalSince(clock.now))
            await waitUntil { clock.hasSleeper(endingAt: due) }
            clock.advance(by: delays.last ?? 0)
        }

        XCTAssertEqual(delays, [1, 2, 4, 8])
        XCTAssertTrue(ledger.waitingIds.contains(id))
        XCTAssertEqual(ledger.rowState(for: testUUID(1)), .waiting)
        XCTAssertEqual(ledger.waitingSummary, "1 action waiting for the network")
    }

    func testARequestOutLongerThanAMomentShowsAsWaiting() async {
        let gate = TestGate()
        let clock = TestIntentClock()
        let transport = RecordingIntentTransport()
        transport.handler = { _ in await gate.wait() }
        let ledger = makeTestLedger(transport: transport, clock: clock)

        ledger.enqueue(request(.flag, 1))
        await waitUntil { transport.calls.count == 1 && clock.sleeperCount == 1 }
        XCTAssertEqual(ledger.rowState(for: testUUID(1)), .none)
        clock.advance(by: MVIntentLedger.Timing().waitingAfter)
        await waitUntil { ledger.rowState(for: testUUID(1)) == .waiting }

        await gate.open()
        await waitUntil { ledger.rowState(for: testUUID(1)) == .none }
    }

    // MARK: - Outcomes

    func testARefusedIntentStopsApplyingAndOffersRetry() async {
        let toasts = MVToastStore()
        let transport = RecordingIntentTransport()
        let attempts = CallCounter()
        transport.handler = { [refusal = refusal(422)] _ in
            if attempts.next() == 1 { throw refusal }
        }
        let ledger = makeTestLedger(transport: transport, toasts: toasts)
        let scope = MVProjectionScope(folderIds: [testFolder], threaded: false)
        let rows = testRows(1...2)

        ledger.enqueue(request(.archive, 1))
        XCTAssertEqual(ledger.project(rows, scope: scope).map(\.id), [testUUID(2)])
        await waitUntil { ledger.intents.first?.state == .failed }

        XCTAssertEqual(ledger.project(rows, scope: scope).map(\.id), [testUUID(1), testUUID(2)])
        XCTAssertEqual(ledger.rowState(for: testUUID(1)), .failed)
        XCTAssertEqual(toasts.current?.message, "Could not archive: refused 422")
        XCTAssertEqual(toasts.current?.actionTitle, "Retry")

        toasts.current?.action?()
        await waitUntil { ledger.intents.first?.state == .done }
        XCTAssertEqual(transport.calls, ["archive 1", "archive 1"])
        XCTAssertEqual(Set(transport.keys), [ledger.intents.first?.id], "a retry was not the same request")
    }

    func testAMessageThatIsGoneRetiresItsIntentQuietly() async {
        let toasts = MVToastStore()
        let transport = RecordingIntentTransport()
        transport.handler = { [refusal = refusal(404)] _ in throw refusal }
        let ledger = makeTestLedger(transport: transport, toasts: toasts)
        var outcome: MVIntentOutcome?

        ledger.enqueue(request(.flag, 1)) { outcome = $0 }
        await waitUntil { outcome != nil }

        XCTAssertEqual(outcome, .gone)
        XCTAssertTrue(ledger.intents.isEmpty)
        XCTAssertNil(toasts.current)
    }

    /// The server refuses a repeated key carrying a different body, so a retried conversation
    /// read sends the ids it resolved the first time, not a re-read of a conversation that has
    /// since changed.
    func testARetriedConversationReadSendsTheSameIdsItFirstResolved() async {
        let clock = TestIntentClock()
        let transport = RecordingIntentTransport()
        let message = { (id: UUID, seen: Bool) in
            ReaderFixtures.message(
                id: id, from: "a@example.org", to: [], subject: "s", html: nil, text: "x", minutesAgo: 1, isSeen: seen)
        }
        let folder = message(testUUID(1), false).folderId
        transport.thread = ThreadResponse(messages: [message(testUUID(1), false), message(testUUID(2), false)])
        let attempts = CallCounter()
        transport.handler = { _ in
            if attempts.next() == 1 { throw MVError.detail("slow down", statusCode: 429) }
        }
        let ledger = makeTestLedger(transport: transport, clock: clock)

        let retryAt = clock.now.addingTimeInterval(1)
        ledger.enqueue(
            MVIntentRequest(
                accountId: testAccount, action: .markRead, messageIds: [testUUID(1)],
                delivery: .conversationRead(folderIds: [folder])))
        await waitUntil { transport.bulkIds.count == 1 && clock.hasSleeper(endingAt: retryAt) }
        transport.thread = ThreadResponse(
            messages: [message(testUUID(1), false), message(testUUID(2), false), message(testUUID(3), false)])
        clock.advance(by: 1)
        await waitUntil { ledger.intents.first?.state == .done }

        XCTAssertEqual(transport.bulkIds, [[testUUID(1), testUUID(2)], [testUUID(1), testUUID(2)]])
        XCTAssertEqual(transport.threadFetches, 1)
    }

    // MARK: - Connectivity and persistence

    func testNothingIsSentOfflineAndEverythingGoesOnceBackOnline() async {
        let connectivity = TestConnectivity(online: false)
        let transport = RecordingIntentTransport()
        let ledger = makeTestLedger(transport: transport, connectivity: connectivity)

        let id = ledger.enqueue(request(.archive, 1))
        await waitUntil { ledger.waitingIds.contains(id) }
        XCTAssertEqual(transport.calls, [])

        connectivity.isOnline = true
        await waitUntil { ledger.intents.first?.state == .done }
        XCTAssertEqual(transport.calls, ["archive 1"])
    }

    /// Relaunching with an action still outstanding: it applies before anything is sent, and is
    /// sent as the same intent — the id that doubles as its idempotency key.
    func testAnOutstandingIntentSurvivesARelaunch() async {
        let persistence = MVMemoryIntentPersistence()
        let first = makeTestLedger(
            transport: RecordingIntentTransport(), connectivity: TestConnectivity(online: false),
            persistence: persistence)
        let id = first.enqueue(request(.archive, 1))
        first.stop()
        XCTAssertEqual(persistence.intents.map(\.id), [id])

        let gate = TestGate()
        let transport = RecordingIntentTransport()
        transport.handler = { _ in await gate.wait() }
        let second = makeTestLedger(transport: transport, persistence: persistence)

        let scope = MVProjectionScope(folderIds: [testFolder], threaded: false)
        XCTAssertEqual(second.project(testRows(1...2), scope: scope).map(\.id), [testUUID(2)])
        await waitUntil { transport.calls == ["archive 1"] }
        await gate.open()
        await waitUntil { second.intents.first?.state == .done }
        XCTAssertEqual(second.intents.map(\.id), [id])
        XCTAssertEqual(transport.keys, [id], "the relaunch sent a request the server cannot match to the first")
    }

    /// A request that was out when the app died may have landed: the message is looked at first,
    /// and the action sent again only because it does not show it yet.
    func testARelaunchChecksWhatWasOutBeforeSendingItAgainAndDropsWhatWasDone() async {
        var sending = MVMailIntent(request: request(.flag, 1), id: testUUID(801), undoes: nil, createdAt: Date())
        sending.state = .sending
        var done = MVMailIntent(request: request(.flag, 2), id: testUUID(802), undoes: nil, createdAt: Date())
        done.state = .done
        let transport = RecordingIntentTransport()
        transport.states = [testUUID(1): MVMessageState(folderId: testFolder, isSeen: false, isFlagged: false)]

        let ledger = makeTestLedger(transport: transport, persistence: MVMemoryIntentPersistence([sending, done]))

        XCTAssertEqual(ledger.intents.map(\.id), [testUUID(801)])
        await waitUntil { transport.calls == ["flag 1"] }
        XCTAssertEqual(transport.lookups, ["state 1"])
    }

    // MARK: - Undo

    func testUndoingAnActionNotYetSentCancelsItWithoutARequest() async {
        let connectivity = TestConnectivity(online: false)
        let transport = RecordingIntentTransport()
        let ledger = makeTestLedger(transport: transport, connectivity: connectivity)
        var outcome: MVIntentOutcome?

        let id = ledger.enqueue(request(.archive, 1)) { outcome = $0 }
        ledger.undo([id])
        connectivity.isOnline = true
        try? await Task.sleep(nanoseconds: 50_000_000)

        XCTAssertEqual(outcome, .cancelled)
        XCTAssertTrue(ledger.intents.isEmpty)
        XCTAssertEqual(transport.calls, [])
    }

    func testUndoingADoneMoveMovesTheMessageBackToItsFolder() async {
        let toasts = MVToastStore()
        let transport = RecordingIntentTransport()
        let ledger = makeTestLedger(transport: transport, toasts: toasts)

        ledger.enqueue(request(.archive, 1), undoToast: "Archived")
        XCTAssertEqual(toasts.current?.message, "Archived")
        await waitUntil { ledger.intents.first?.state == .done }
        toasts.current?.action?()
        await waitUntil { ledger.intents.count == 2 && ledger.intents.allSatisfy { $0.state == .done } }

        XCTAssertEqual(transport.calls, ["archive 1", "move 1"])
        XCTAssertEqual(ledger.intents.last?.targetFolderId, testFolder)
        XCTAssertFalse(ledger.hiddenMessageIds.contains(testUUID(1)), "the moved-back message still reads as hidden")
    }

    func testUndoingWhileTheRequestIsOutReversesItOnceItLands() async {
        let gate = TestGate()
        let transport = RecordingIntentTransport()
        transport.handler = { call in
            if call == "trash 1" { await gate.wait() }
        }
        let ledger = makeTestLedger(transport: transport)

        let id = ledger.enqueue(request(.trash, 1))
        await waitUntil { transport.calls.count == 1 }
        ledger.undo([id])
        XCTAssertEqual(transport.calls, ["trash 1"])
        await gate.open()
        await waitUntil { transport.calls.count == 2 }

        XCTAssertEqual(transport.calls, ["trash 1", "move 1"])
    }

    func testUndoingAStarUnstars() async {
        let transport = RecordingIntentTransport()
        let ledger = makeTestLedger(transport: transport)

        let id = ledger.enqueue(request(.flag, 1))
        await waitUntil { ledger.intents.first?.state == .done }
        ledger.undo([id])
        await waitUntil { transport.calls.count == 2 }

        XCTAssertEqual(transport.calls, ["flag 1", "unflag 1"])
    }

    // MARK: - Retirement

    /// Data read after an intent settled already carries it, so the intent stops applying there
    /// — and stays in the ledger, still undoable.
    func testADoneIntentStopsApplyingToNewerDataButCanStillBeUndone() async {
        let transport = RecordingIntentTransport()
        let ledger = makeTestLedger(transport: transport)
        let scope = MVProjectionScope(folderIds: [testFolder], threaded: false)

        let id = ledger.enqueue(request(.archive, 1))
        await waitUntil { ledger.intents.first?.state == .done }
        let before = MVIntentProjection.rows(
            testRows(1...2), applying: ledger.intents, baseSequence: ledger.sequence - 1, scope: scope)
        let after = MVIntentProjection.rows(
            testRows(1...2), applying: ledger.intents, baseSequence: ledger.sequence, scope: scope)
        XCTAssertEqual(before.map(\.id), [testUUID(2)])
        XCTAssertEqual(after.map(\.id), [testUUID(1), testUUID(2)])

        ledger.undo([id])
        await waitUntil { transport.calls.count == 2 }
        XCTAssertEqual(transport.calls, ["archive 1", "move 1"])
    }

    /// The safety net: no observer ever reads again, and the intent still leaves the ledger — its
    /// effect handed to the data read before it.
    func testADoneIntentRetiresAfterItsRetentionAndIsFoldedIntoOlderData() async {
        let clock = TestIntentClock()
        let transport = RecordingIntentTransport()
        let ledger = makeTestLedger(transport: transport, clock: clock)
        let observer = TestIntentObserver(sequence: 0)
        ledger.addObserver(observer)

        ledger.enqueue(request(.archive, 1))
        await waitUntil { ledger.intents.first?.state == .done && clock.sleeperCount == 1 }
        clock.advance(by: MVIntentLedger.Timing().doneRetention - 1)
        XCTAssertEqual(ledger.intents.count, 1)
        clock.advance(by: 1)
        await waitUntil { ledger.intents.isEmpty }

        XCTAssertEqual(observer.retired.map(\.messageIds), [[testUUID(1)]])
        XCTAssertEqual(observer.settled.map(\.messageIds), [[testUUID(1)]])
    }

    func testANewIntentKeepsTheRowsAnObserverHolds() async {
        let ledger = makeTestLedger(
            transport: RecordingIntentTransport(), connectivity: TestConnectivity(online: false))
        let observer = TestIntentObserver(sequence: 0)
        observer.rows = testRows(1...3)
        ledger.addObserver(observer)

        ledger.enqueue(MVIntentRequest(accountId: testAccount, action: .trash, messageIds: [testUUID(2)]))

        XCTAssertEqual(ledger.intents.first?.snapshots.map(\.id), [testUUID(2)])
    }
}

@MainActor
final class TestIntentObserver: MVIntentObserver {
    var sequence: Int
    var rows: [MessageSummary] = []
    private(set) var retired: [MVMailIntent] = []
    private(set) var settled: [MVMailIntent] = []

    init(sequence: Int) {
        self.sequence = sequence
    }

    func intentSnapshots(for messageIds: Set<UUID>) -> [MessageSummary] {
        rows.filter { messageIds.contains($0.id) }
    }

    func intentsWillRetire(_ intents: [MVMailIntent]) {
        retired += intents
    }

    func intentsDidSettle(_ intents: [MVMailIntent]) {
        settled += intents
    }
}

extension MVIntentLedger {
    /// Rows read before any intent — what a list holding `rows` since before the actions shows.
    func project(_ rows: [MessageSummary], scope: MVProjectionScope) -> [MessageSummary] {
        MVIntentProjection.rows(rows, applying: intents, baseSequence: 0, scope: scope)
    }
}

final class MVIntentProjectionTests: XCTestCase {
    private let scope = MVProjectionScope(folderIds: [testFolder], threaded: false)
    private let archiveFolder = testUUID(701)

    private func intent(
        _ action: MVBulkAction, _ ids: [Int], target: UUID? = nil, state: MVMailIntent.Phase = .pending,
        settled: Int? = nil, delivery: MVMailIntent.Delivery = .message, snapshots: [MessageSummary] = []
    ) -> MVMailIntent {
        var intent = MVMailIntent(
            request: MVIntentRequest(
                accountId: testAccount, action: action, targetFolderId: target, messageIds: ids.map(testUUID),
                delivery: delivery, snapshots: snapshots), id: UUID(), undoes: nil, createdAt: testReceivedBase)
        intent.state = state
        intent.settledSequence = settled
        return intent
    }

    func testALeavingActionHidesItsRows() {
        let rows = MVIntentProjection.rows(
            testRows(1...3), applying: [intent(.archive, [2])], baseSequence: 0, scope: scope)
        XCTAssertEqual(rows.map(\.id), [testUUID(1), testUUID(3)])
    }

    func testReadAndStarOverrideTheServersValues() {
        let rows = MVIntentProjection.rows(
            testRows(1...2), applying: [intent(.markRead, [1]), intent(.flag, [2])], baseSequence: 0, scope: scope)
        XCTAssertEqual(rows.map(\.isSeen), [true, false])
        XCTAssertEqual(rows.map(\.isFlagged), [false, true])
    }

    func testAConversationReadClearsTheRowsUnreadCount() {
        let row = testRow(1, unreadInThread: 3)
        let rows = MVIntentProjection.rows(
            [row], applying: [intent(.markRead, [1], delivery: .conversationRead(folderIds: [testFolder]))],
            baseSequence: 0, scope: scope)
        XCTAssertEqual(rows.first?.isSeen, true)
        XCTAssertEqual(rows.first?.unreadInThread, 0)
    }

    /// An undone archive: the archive hides the row, the move back into this list's folder puts
    /// its snapshot back in its sorted place.
    func testAMoveIntoTheListPutsItsSnapshotBackInPlace() {
        let archived = intent(.archive, [2], state: .done, settled: 1)
        let back = intent(.move, [2], target: testFolder, snapshots: [testRow(2)])
        let rows = MVIntentProjection.rows(
            [testRow(1), testRow(3)], applying: [archived, back], baseSequence: 1, scope: scope)
        XCTAssertEqual(rows.map(\.id), [testUUID(1), testUUID(2), testUUID(3)])
    }

    func testASnapshotBelowAWindowWithOlderRowsUnloadedIsNotPutBack() {
        let back = intent(.move, [9], target: testFolder, snapshots: [testRow(9)])
        let window = MVProjectionScope(folderIds: [testFolder], threaded: false, hasOlder: true)
        let rows = MVIntentProjection.rows(testRows(1...2), applying: [back], baseSequence: 0, scope: window)
        XCTAssertEqual(rows.map(\.id), [testUUID(1), testUUID(2)])
    }

    func testASnapshotAboveAWindowWithNewerRowsUnloadedIsNotPutBack() {
        let back = intent(.move, [1], target: testFolder, snapshots: [testRow(1)])
        let window = MVProjectionScope(folderIds: [testFolder], threaded: false, hasNewer: true)
        let rows = MVIntentProjection.rows(testRows(2...3), applying: [back], baseSequence: 0, scope: window)
        XCTAssertEqual(rows.map(\.id), [testUUID(2), testUUID(3)])
    }

    func testAMoveElsewhereHidesTheRow() {
        let rows = MVIntentProjection.rows(
            testRows(1...2), applying: [intent(.move, [1], target: archiveFolder)], baseSequence: 0, scope: scope)
        XCTAssertEqual(rows.map(\.id), [testUUID(2)])
    }

    /// Done at sequence 5: a read that began at 4 predates it and still needs it; one that began
    /// at 5 already carries it, and whatever that read says wins.
    func testADoneIntentAppliesOnlyToDataReadBeforeItSettled() {
        let done = intent(.archive, [1], state: .done, settled: 5)
        XCTAssertEqual(
            MVIntentProjection.rows(testRows(1...2), applying: [done], baseSequence: 4, scope: scope).count, 1)
        XCTAssertEqual(
            MVIntentProjection.rows(testRows(1...2), applying: [done], baseSequence: 5, scope: scope).count, 2)
    }

    func testARefusedIntentAppliesToNothing() {
        let refused = intent(.archive, [1], state: .failed, settled: 5)
        XCTAssertEqual(
            MVIntentProjection.rows(testRows(1...2), applying: [refused], baseSequence: 0, scope: scope).count, 2)
    }

    func testReadingAMessageOverAReadThatAlreadyHasItChangesNothing() {
        let row = testRow(1, seen: true, unreadInThread: 2)
        let threaded = MVProjectionScope(folderIds: [testFolder], threaded: true)
        let rows = MVIntentProjection.rows([row], applying: [intent(.markRead, [1])], baseSequence: 0, scope: threaded)
        XCTAssertEqual(rows.first?.unreadInThread, 2)
    }
}
