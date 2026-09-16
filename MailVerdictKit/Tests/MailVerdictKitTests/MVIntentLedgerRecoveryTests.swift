import XCTest

@testable import MailVerdictKit

#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif

/// The ledger when things go wrong between the phone and the server: answers that never come back,
/// a server that ignores idempotency keys, undo racing a request, expired credentials, a queue left
/// too long, and a persisted file this build cannot fully read.
@MainActor
final class MVIntentLedgerRecoveryTests: XCTestCase {
    private let archiveFolder = testUUID(701)
    private let scope = MVProjectionScope(folderIds: [testFolder], threaded: false)

    private func request(_ action: MVBulkAction, _ n: Int, target: UUID? = nil) -> MVIntentRequest {
        MVIntentRequest(
            accountId: testAccount, action: action, targetFolderId: target, messageIds: [testUUID(n)],
            originFolderIds: [testUUID(n): testFolder], snapshots: [testRow(n)])
    }

    private func visible(_ ledger: MVIntentLedger) -> [UUID] {
        ledger.project(testRows(1...2), scope: scope).map(\.id)
    }

    // MARK: - An answer that never came back

    /// No answer after the request left, and the message already sits in Archive: it landed, so it
    /// is not sent again — an older server that ignores the key would archive it twice.
    func testALostAnswerIsCheckedAndNotResentWhenTheActionLanded() async {
        let clock = TestIntentClock()
        let transport = RecordingIntentTransport()
        let attempts = CallCounter()
        transport.handler = { _ in
            if attempts.next() == 1 { throw MVError.http(statusCode: 504, reason: "Gateway Timeout") }
        }
        transport.states = [testUUID(1): MVMessageState(folderId: archiveFolder)]
        let ledger = makeTestLedger(transport: transport, clock: clock)

        let retryAt = clock.now.addingTimeInterval(1)
        ledger.enqueue(request(.archive, 1))
        await waitUntil { ledger.intents.first?.mayHaveLanded == true && clock.hasSleeper(endingAt: retryAt) }
        clock.advance(by: 1)
        await waitUntil { ledger.intents.first?.state == .done }

        XCTAssertEqual(transport.calls, ["archive 1"])
        XCTAssertEqual(transport.lookups, ["state 1"])
    }

    func testALostAnswerIsSentAgainWhenTheMessageDoesNotShowItYet() async {
        let clock = TestIntentClock()
        let transport = RecordingIntentTransport()
        let attempts = CallCounter()
        transport.handler = { _ in
            if attempts.next() == 1 { throw URLError(.timedOut) }
        }
        transport.states = [testUUID(1): MVMessageState(folderId: testFolder)]
        let ledger = makeTestLedger(transport: transport, clock: clock)

        let retryAt = clock.now.addingTimeInterval(1)
        ledger.enqueue(request(.archive, 1))
        await waitUntil { ledger.intents.first?.mayHaveLanded == true && clock.hasSleeper(endingAt: retryAt) }
        clock.advance(by: 1)
        await waitUntil { ledger.intents.first?.state == .done }

        XCTAssertEqual(transport.calls, ["archive 1", "archive 1"])
        XCTAssertEqual(transport.lookups, ["state 1"])
    }

    /// A request that never got onto the wire is not looked up before it goes again.
    func testARequestThatNeverLeftIsNotCheckedBeforeRetrying() async {
        let clock = TestIntentClock()
        let transport = RecordingIntentTransport()
        let attempts = CallCounter()
        transport.handler = { _ in
            if attempts.next() == 1 { throw URLError(.notConnectedToInternet) }
        }
        let ledger = makeTestLedger(transport: transport, clock: clock)

        let retryAt = clock.now.addingTimeInterval(1)
        ledger.enqueue(request(.flag, 1))
        await waitUntil { transport.calls.count == 1 && clock.hasSleeper(endingAt: retryAt) }
        clock.advance(by: 1)
        await waitUntil { ledger.intents.first?.state == .done }

        XCTAssertEqual(transport.lookups, [])
    }

    func testAnActionThatKeepsFailingFailsVisiblyAfterItsLastAttempt() async {
        let clock = TestIntentClock()
        let toasts = MVToastStore()
        let transport = RecordingIntentTransport()
        transport.handler = { _ in throw MVError.http(statusCode: 429, reason: "Too Many Requests") }
        var timing = MVIntentLedger.Timing()
        timing.maxAttempts = 3
        let ledger = makeTestLedger(transport: transport, toasts: toasts, clock: clock, timing: timing)

        ledger.enqueue(request(.archive, 1))
        for attempt in 1...2 {
            await waitUntil { transport.calls.count == attempt && ledger.intents.first?.state == .pending }
            let due = ledger.intents.first?.nextAttemptAt ?? clock.now
            await waitUntil { clock.hasSleeper(endingAt: due) }
            clock.advance(by: due.timeIntervalSince(clock.now))
        }
        await waitUntil { ledger.intents.first?.state == .failed }

        XCTAssertEqual(transport.calls.count, 3)
        XCTAssertEqual(visible(ledger), [testUUID(1), testUUID(2)])
        XCTAssertEqual(
            toasts.current?.message, "Could not archive: Still failing after 3 attempts: HTTP 429: Too Many Requests")
        XCTAssertEqual(ledger.failedIntents.count, 1)
    }

    /// The spam ruling endpoint answers 200 with `success: false` when it could not apply it.
    func testASingleActionTheServerDidNotApplyFails() async {
        let transport = RecordingIntentTransport()
        transport.messageResponseSuccess = false
        let ledger = makeTestLedger(transport: transport)

        ledger.enqueue(request(.spam, 1))
        await waitUntil { ledger.intents.first?.state != .sending && ledger.intents.first?.state != .pending }

        XCTAssertEqual(ledger.intents.first?.state, .failed)
        XCTAssertEqual(ledger.intents.first?.lastError, "Feedback processing failed")
    }

    // MARK: - Undo racing a request

    /// Undo after an attempt that got no answer: it may have landed, so it is reversed rather than
    /// dropped — a move back to where the message was changes nothing if it never left.
    func testUndoAfterAnUnansweredAttemptMovesTheMessageBack() async {
        let clock = TestIntentClock()
        let transport = RecordingIntentTransport()
        let attempts = CallCounter()
        transport.handler = { call in
            if call == "archive 1", attempts.next() == 1 { throw MVError.http(statusCode: 502, reason: "Bad Gateway") }
        }
        let ledger = makeTestLedger(transport: transport, clock: clock)

        let id = ledger.enqueue(request(.archive, 1))
        await waitUntil { ledger.intents.first?.mayHaveLanded == true && ledger.intents.first?.state == .pending }
        ledger.undo([id])

        XCTAssertEqual(visible(ledger), [testUUID(1), testUUID(2)], "the undone row did not come back at once")
        await waitUntil { transport.calls.count == 2 }
        XCTAssertEqual(transport.calls, ["archive 1", "move 1"])
        XCTAssertEqual(ledger.intents.first?.targetFolderId, testFolder)
        XCTAssertEqual(
            transport.expected.last, [testUUID(1): testUUID(701)],
            "the move back went out without saying where it expects the message")
    }

    func testUndoWhileTheRequestIsOutShowsTheRowAtOnce() async {
        let gate = TestGate()
        let transport = RecordingIntentTransport()
        transport.handler = { call in
            if call == "trash 1" { await gate.wait() }
        }
        let persistence = MVMemoryIntentPersistence()
        let ledger = makeTestLedger(transport: transport, persistence: persistence)

        let id = ledger.enqueue(request(.trash, 1))
        await waitUntil { transport.calls.count == 1 }
        ledger.undo([id])

        XCTAssertEqual(visible(ledger), [testUUID(1), testUUID(2)])
        XCTAssertFalse(ledger.hiddenMessageIds.contains(testUUID(1)))
        XCTAssertEqual(persistence.intents.first?.undoRequested, true, "the undo lived only in memory")
        await gate.open()
        await waitUntil { transport.calls.count == 2 }
    }

    /// Killed with the request out and Undo already tapped: the relaunch reverses it rather than
    /// sending the original again.
    func testAnUndoRequestedBeforeARelaunchIsReversedNotResent() async {
        var undone = MVMailIntent(request: request(.trash, 1), id: testUUID(803), undoes: nil, createdAt: Date())
        undone.state = .sending
        undone.undoRequested = true
        let transport = RecordingIntentTransport()

        let ledger = makeTestLedger(transport: transport, persistence: MVMemoryIntentPersistence([undone]))
        await waitUntil { ledger.intents.first?.state == .done }

        XCTAssertEqual(transport.calls, ["move 1"])
        XCTAssertEqual(ledger.intents.map(\.undoes), [testUUID(803)])
    }

    // MARK: - Credentials

    func testARefusedCredentialHoldsTheActionWithoutFailingIt() async {
        let transport = RecordingIntentTransport()
        let attempts = CallCounter()
        transport.handler = { _ in
            if attempts.next() == 1 { throw MVError.detail("Not authenticated", statusCode: 401) }
        }
        let ledger = makeTestLedger(transport: transport)

        ledger.enqueue(request(.archive, 1))
        await waitUntil { ledger.isHeld }

        XCTAssertEqual(ledger.intents.first?.state, .pending)
        XCTAssertEqual(ledger.intents.first?.attempts, 0)
        XCTAssertEqual(visible(ledger), [testUUID(2)], "a held action stopped applying")
        try? await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(transport.calls.count, 1, "a held ledger kept sending")

        ledger.resume()
        await waitUntil { ledger.intents.first?.state == .done }
        XCTAssertEqual(transport.calls.count, 2)
    }

    // MARK: - Conversation reads

    /// A message marked unread after a conversation was marked read stays unread, whichever
    /// request reaches the server first.
    func testALaterUnreadIsNeitherSweptIntoAConversationReadNorOvertakenByIt() async {
        let clock = TestIntentClock()
        let transport = RecordingIntentTransport()
        let detail = { (id: UUID) in
            ReaderFixtures.message(
                id: id, from: "a@example.org", to: [], subject: "s", html: nil, text: "x", minutesAgo: 1, isSeen: false)
        }
        let folder = detail(testUUID(1)).folderId
        transport.thread = ThreadResponse(messages: [detail(testUUID(1)), detail(testUUID(2)), detail(testUUID(3))])
        let attempts = CallCounter()
        transport.handler = { call in
            if call == "mark_read 1", attempts.next() == 1 { throw MVError.detail("slow down", statusCode: 429) }
        }
        let ledger = makeTestLedger(transport: transport, clock: clock)

        let retryAt = clock.now.addingTimeInterval(1)
        ledger.enqueue(
            MVIntentRequest(
                accountId: testAccount, action: .markRead, messageIds: [testUUID(1)],
                delivery: .conversationRead(folderIds: [folder])))
        await waitUntil { transport.calls.count == 1 && clock.hasSleeper(endingAt: retryAt) }
        ledger.enqueue(request(.markUnread, 2))
        ledger.enqueue(request(.markUnread, 3))
        try? await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(transport.calls, ["mark_read 1"], "an unread overtook the conversation read it follows")
        clock.advance(by: 1)
        await waitUntil { transport.calls.count == 4 }

        XCTAssertEqual(transport.calls, ["mark_read 1", "mark_read 1", "mark_unread 2", "mark_unread 3"])
    }

    func testAConversationReadResolvedAfterALaterUnreadLeavesThatMessageOut() async {
        let connectivity = TestConnectivity(online: false)
        let transport = RecordingIntentTransport()
        let detail = { (id: UUID) in
            ReaderFixtures.message(
                id: id, from: "a@example.org", to: [], subject: "s", html: nil, text: "x", minutesAgo: 1, isSeen: false)
        }
        let folder = detail(testUUID(1)).folderId
        transport.thread = ThreadResponse(messages: [detail(testUUID(1)), detail(testUUID(2))])
        let ledger = makeTestLedger(transport: transport, connectivity: connectivity)

        ledger.enqueue(
            MVIntentRequest(
                accountId: testAccount, action: .markRead, messageIds: [testUUID(1)],
                delivery: .conversationRead(folderIds: [folder])))
        ledger.enqueue(request(.markUnread, 2))
        connectivity.isOnline = true
        await waitUntil { ledger.intents.allSatisfy { $0.state == .done } }

        XCTAssertEqual(transport.bulkIds.first, [testUUID(1)])
        XCTAssertEqual(Set(transport.keys.compactMap { $0 }), Set(ledger.intents.map(\.id)))
    }

    // MARK: - A queue left too long

    /// Unsent for longer than the expiry: the mailbox may have moved on, so nothing goes out until
    /// the person says so.
    func testAnActionLeftUnsentTooLongWaitsForThePersonToSendIt() async {
        let clock = TestIntentClock()
        let connectivity = TestConnectivity(online: false)
        let transport = RecordingIntentTransport()
        let ledger = makeTestLedger(transport: transport, clock: clock, connectivity: connectivity)

        let id = ledger.enqueue(request(.trash, 1))
        clock.advance(by: MVIntentLedger.Timing().pendingExpiry)
        connectivity.isOnline = true
        await waitUntil { ledger.unsentIntents.count == 1 }
        try? await Task.sleep(nanoseconds: 50_000_000)

        XCTAssertEqual(transport.calls, [])
        XCTAssertEqual(ledger.attentionSummary, "1 action not sent")
        XCTAssertEqual(ledger.rowState(for: testUUID(1)), .waiting)

        ledger.confirmSend([id])
        await waitUntil { ledger.intents.first?.state == .done }
        XCTAssertEqual(transport.calls, ["trash 1"])
        XCTAssertNil(ledger.attentionSummary)
    }

    func testDiscardingAnExpiredActionSendsNothing() async {
        let clock = TestIntentClock()
        let transport = RecordingIntentTransport()
        let connectivity = TestConnectivity(online: false)
        let ledger = makeTestLedger(transport: transport, clock: clock, connectivity: connectivity)

        let id = ledger.enqueue(request(.trash, 1))
        clock.advance(by: MVIntentLedger.Timing().pendingExpiry)
        connectivity.isOnline = true
        await waitUntil { ledger.unsentIntents.count == 1 }
        ledger.discard([id])
        try? await Task.sleep(nanoseconds: 50_000_000)

        XCTAssertTrue(ledger.intents.isEmpty)
        XCTAssertEqual(transport.calls, [])
        XCTAssertEqual(visible(ledger), [testUUID(1), testUUID(2)])
    }

    // MARK: - Keys, stopping, idle

    func testBulkAndConversationRequestsCarryTheirIntentsKeyOnEveryAttempt() async {
        let clock = TestIntentClock()
        let transport = RecordingIntentTransport()
        let detail = ReaderFixtures.message(
            id: testUUID(5), from: "a@example.org", to: [], subject: "s", html: nil, text: "x", minutesAgo: 1,
            isSeen: false)
        transport.thread = ThreadResponse(messages: [detail])
        let attempts = CallCounter()
        transport.handler = { _ in
            if attempts.next() <= 2 { throw MVError.detail("slow down", statusCode: 429) }
        }
        let ledger = makeTestLedger(transport: transport, clock: clock)

        let bulk = ledger.enqueue(
            MVIntentRequest(
                accountId: testAccount, action: .trash, messageIds: [testUUID(1), testUUID(2)],
                delivery: .bulk(expandThreads: true)))
        let conversation = ledger.enqueue(
            MVIntentRequest(
                accountId: testAccount, action: .markRead, messageIds: [testUUID(5)],
                delivery: .conversationRead(folderIds: [detail.folderId])))
        await waitUntil {
            transport.calls.count == 2 && ledger.intents.allSatisfy { $0.state == .pending } && clock.sleeperCount > 0
        }
        clock.advance(by: 1)
        await waitUntil { ledger.intents.allSatisfy { $0.state == .done } }

        XCTAssertEqual(transport.calls, ["trash 1", "mark_read 5", "trash 1", "mark_read 5"])
        XCTAssertEqual(transport.keys, [bulk, conversation, bulk, conversation])
        XCTAssertEqual(transport.timeouts.count, 5, "the conversation lookup went out without the request timeout")
    }

    /// A ledger for a connection that has gone away never writes the file a new one may own.
    func testAStoppedLedgerWritesNothing() async {
        let persistence = MVMemoryIntentPersistence()
        let gate = TestGate()
        let transport = RecordingIntentTransport()
        transport.handler = { _ in await gate.wait() }
        let ledger = makeTestLedger(transport: transport, persistence: persistence)

        let id = ledger.enqueue(request(.archive, 1))
        await waitUntil { transport.calls.count == 1 }
        ledger.stop()
        let written = persistence.intents
        ledger.undo([id])
        ledger.enqueue(request(.flag, 2))
        await gate.open()
        try? await Task.sleep(nanoseconds: 50_000_000)

        XCTAssertEqual(persistence.intents, written)
    }

    func testWaitingUntilIdleReturnsOnceEverythingIsSent() async {
        let gate = TestGate()
        let transport = RecordingIntentTransport()
        transport.handler = { _ in await gate.wait() }
        let ledger = makeTestLedger(transport: transport)
        ledger.enqueue(request(.archive, 1))
        var idle = false
        let waiter = Task { @MainActor in
            await ledger.waitUntilIdle()
            idle = true
        }

        try? await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertFalse(idle)
        await gate.open()
        await waiter.value
        XCTAssertTrue(idle)
    }

    // MARK: - Classification and persistence

    func testHowEachAnswerIsTreated() {
        XCTAssertEqual(
            MVIntentDelivery.classify(MVError.decoding("x")), .delivered(affectedCount: nil, sources: []),
            "a 2xx with an unreadable body was applied")
        XCTAssertEqual(MVIntentDelivery.classify(MVError.detail("x", statusCode: 404)), .gone)
        XCTAssertEqual(MVIntentDelivery.classify(MVError.detail("x", statusCode: 403)), .hold("x"))
        XCTAssertEqual(
            MVIntentDelivery.classify(MVError.proxyRequiresBrowserLogin),
            .hold(MVError.proxyRequiresBrowserLogin.userMessage))
        XCTAssertEqual(
            MVIntentDelivery.classify(MVError.detail("x", statusCode: 429)), .retry("x", mayHaveLanded: false))
        XCTAssertEqual(
            MVIntentDelivery.classify(MVError.detail("x", statusCode: 503)), .busy("x"))
        XCTAssertEqual(
            MVIntentDelivery.classify(MVError.detail("x", statusCode: 502)), .retry("x", mayHaveLanded: true))
        XCTAssertEqual(MVIntentDelivery.classify(MVError.detail("x", statusCode: 409)), .refused("x"))
        guard case .retry(_, false) = MVIntentDelivery.classify(URLError(.cannotConnectToHost)) else {
            return XCTFail("a request that never connected counted as maybe landed")
        }
        guard case .retry(_, true) = MVIntentDelivery.classify(URLError(.timedOut)) else {
            return XCTFail("a timed-out request counted as never sent")
        }
    }

    func testOneUnreadableRecordLeavesTheOthers() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("intents-\(UUID()).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let persistence = MVFileIntentPersistence(url: url)
        let intents = [1, 2].map {
            MVMailIntent(request: request(.flag, $0), id: testUUID(900 + $0), undoes: nil, createdAt: Date())
        }
        persistence.save(intents)
        var document = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        var records = try XCTUnwrap(document["intents"] as? [[String: Any]])
        records[0]["action"] = "no_such_action"
        records[1]["snapshots"] = [["id": "not a message"]]
        document["intents"] = records
        try JSONSerialization.data(withJSONObject: document).write(to: url)

        let loaded = persistence.load()

        XCTAssertEqual(loaded.map(\.id), [testUUID(902)])
        XCTAssertEqual(loaded.first?.snapshots, [], "an unreadable snapshot took its intent with it")
    }

    func testAFileThisBuildCannotReadIsSetAsideRatherThanOverwritten() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("intents-\(UUID()).json")
        let aside = url.appendingPathExtension("unreadable")
        defer {
            try? FileManager.default.removeItem(at: url)
            try? FileManager.default.removeItem(at: aside)
        }
        try Data(#"{"version": 99, "intents": []}"#.utf8).write(to: url)

        XCTAssertEqual(MVFileIntentPersistence(url: url).load(), [])
        XCTAssertTrue(FileManager.default.fileExists(atPath: aside.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }

    func testOneServerMapsToOneFileAndTwoServersNeverShareOne() {
        XCTAssertEqual(
            MVFileIntentPersistence.fileKey("https://Mail.Example.com/"),
            MVFileIntentPersistence.fileKey("https://mail.example.com"))
        XCTAssertNotEqual(
            MVFileIntentPersistence.fileKey("https://a-b.com"), MVFileIntentPersistence.fileKey("https://a.b.com"))
    }
}
