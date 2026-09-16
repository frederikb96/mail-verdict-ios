import XCTest

@testable import MailVerdictKit

#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif

/// Undo and Discard never move a message back from somewhere they cannot name, reconciling looks
/// for the action's own result, and nothing destroys a folder while actions on its account are
/// still on their way.
@MainActor
final class MVIntentReversalTests: XCTestCase {
    private let archive = testRoleFolders["archive"]!
    private let taxes = testUUID(760)

    private func request(_ action: MVBulkAction, _ n: Int, target: UUID? = nil) -> MVIntentRequest {
        MVIntentRequest(
            accountId: testAccount, action: action, targetFolderId: target, messageIds: [testUUID(n)],
            originFolderIds: [testUUID(n): testFolder], snapshots: [testRow(n)])
    }

    // MARK: - Reversals are always guarded

    /// Timed out, left offline past the hour, then Discarded: the move back expects the message in
    /// Archive, so one filed into Taxes on another device meanwhile stays there.
    func testDiscardingAHeldActionThatMayHaveLandedExpectsTheMessageWhereTheActionFilesIt() async {
        let clock = TestIntentClock()
        let connectivity = TestConnectivity(online: true)
        let transport = RecordingIntentTransport()
        transport.handler = { call in
            if call == "archive 1" { throw URLError(.timedOut) }
        }
        let ledger = makeTestLedger(transport: transport, clock: clock, connectivity: connectivity)

        let id = ledger.enqueue(request(.archive, 1))
        await waitUntil { ledger.intents.first?.mayHaveLanded == true && ledger.intents.first?.state == .pending }
        connectivity.isOnline = false
        clock.advance(by: MVIntentLedger.Timing().pendingExpiry + 1)
        connectivity.isOnline = true
        await waitUntil { ledger.unsentIntents.count == 1 }
        ledger.discard([id])
        await waitUntil { transport.calls.count == 2 }

        XCTAssertEqual(transport.calls, ["archive 1", "move 1"])
        XCTAssertEqual(transport.expected.last, [testUUID(1): archive])
    }

    func testAMoveIsUndoneExpectingItsOwnTargetWhenNoAnswerSaidWhereItWent() async {
        let clock = TestIntentClock()
        let transport = RecordingIntentTransport()
        let attempts = CallCounter()
        transport.handler = { call in
            if call == "move 1", attempts.next() == 1 { throw MVError.http(statusCode: 504, reason: "Gateway Timeout") }
        }
        let ledger = makeTestLedger(transport: transport, clock: clock)

        let id = ledger.enqueue(request(.move, 1, target: taxes))
        await waitUntil { ledger.intents.first?.mayHaveLanded == true && ledger.intents.first?.state == .pending }
        ledger.undo([id])
        await waitUntil { transport.calls.count == 2 }

        XCTAssertEqual(transport.expected.last, [testUUID(1): taxes])
    }

    /// An action concluded done by reading the message records where it found it, so its undo is
    /// guarded like any other.
    func testAnActionFoundAlreadyAppliedIsUndoneExpectingWhereItWasFound() async {
        let clock = TestIntentClock()
        let transport = RecordingIntentTransport()
        let attempts = CallCounter()
        transport.handler = { _ in
            if attempts.next() == 1 { throw MVError.http(statusCode: 502, reason: "Bad Gateway") }
        }
        transport.states = [testUUID(1): MVMessageState(folderId: archive)]
        let ledger = makeTestLedger(transport: transport, clock: clock)

        let retryAt = clock.now.addingTimeInterval(1)
        let id = ledger.enqueue(request(.archive, 1))
        await waitUntil { ledger.intents.first?.mayHaveLanded == true && clock.hasSleeper(endingAt: retryAt) }
        clock.advance(by: 1)
        await waitUntil { ledger.intents.first?.state == .done }
        XCTAssertEqual(ledger.intents.first?.filedFolderIds, [testUUID(1): archive])
        ledger.undo([id])
        await waitUntil { transport.calls.count == 2 }

        XCTAssertEqual(transport.calls, ["archive 1", "move 1"])
        XCTAssertEqual(transport.expected.last, [testUUID(1): archive])
    }

    /// No Archive folder to expect the message in: the undo is refused rather than sent blind.
    func testAnUndoWithNowhereToExpectTheMessageIsNotSent() async {
        let clock = TestIntentClock()
        let toasts = MVToastStore()
        let transport = RecordingIntentTransport()
        transport.folders = []
        let attempts = CallCounter()
        transport.handler = { call in
            if call == "archive 1", attempts.next() == 1 { throw URLError(.timedOut) }
        }
        let ledger = makeTestLedger(transport: transport, toasts: toasts, clock: clock)

        let id = ledger.enqueue(request(.archive, 1))
        await waitUntil { ledger.intents.first?.mayHaveLanded == true && ledger.intents.first?.state == .pending }
        ledger.undo([id])
        await waitUntil { ledger.intents.first?.state == .failed }

        XCTAssertEqual(transport.calls, ["archive 1"])
        XCTAssertEqual(
            toasts.current?.message, "Could not undo: There is no folder the action could have left the message in")
    }

    // MARK: - Reconciling looks for the action's own result

    /// Moved to Taxes by someone else while the archive's answer was lost: that is not the archive
    /// having landed, so it is sent — guarded — and the server leaves the message where it is.
    func testAMessageSomeoneElseMovedIsNotTakenForTheActionHavingLanded() async {
        let clock = TestIntentClock()
        let transport = RecordingIntentTransport()
        let attempts = CallCounter()
        transport.handler = { _ in
            if attempts.next() == 1 { throw MVError.http(statusCode: 502, reason: "Bad Gateway") }
        }
        transport.states = [testUUID(1): MVMessageState(folderId: taxes)]
        let ledger = makeTestLedger(transport: transport, clock: clock)

        let retryAt = clock.now.addingTimeInterval(1)
        ledger.enqueue(request(.spam, 1))
        await waitUntil { ledger.intents.first?.mayHaveLanded == true && clock.hasSleeper(endingAt: retryAt) }
        clock.advance(by: 1)
        await waitUntil { transport.calls.count == 2 }

        XCTAssertEqual(transport.calls, ["spam 1", "spam 1"])
        XCTAssertEqual(transport.expected.last, [testUUID(1): testFolder])
    }

    // MARK: - Busy servers and held credentials

    /// 503: the server is still applying the first attempt. Asked again shortly, without reading
    /// messages or spending an attempt.
    func testABusyServerIsAskedAgainWithoutCountingOrLookingUp() async {
        let clock = TestIntentClock()
        let transport = RecordingIntentTransport()
        let attempts = CallCounter()
        transport.handler = { _ in
            if attempts.next() <= 3 { throw MVError.detail("still running", statusCode: 503) }
        }
        var timing = MVIntentLedger.Timing()
        timing.maxAttempts = 2
        let ledger = makeTestLedger(transport: transport, clock: clock, timing: timing)

        ledger.enqueue(request(.archive, 1))
        for attempt in 1...3 {
            await waitUntil { transport.calls.count == attempt && ledger.intents.first?.state == .pending }
            let due = ledger.intents.first?.nextAttemptAt ?? clock.now
            XCTAssertEqual(due.timeIntervalSince(clock.now), timing.busyRetryDelay, accuracy: 0.001)
            await waitUntil { clock.hasSleeper(endingAt: due) }
            clock.advance(by: timing.busyRetryDelay)
        }
        await waitUntil { ledger.intents.first?.state == .done }

        XCTAssertEqual(transport.lookups, [])
        XCTAssertEqual(transport.calls.count, 4)
    }

    func testARefusedCredentialIsTriedAgainAfterAWhile() async {
        let clock = TestIntentClock()
        let transport = RecordingIntentTransport()
        let attempts = CallCounter()
        transport.handler = { _ in
            if attempts.next() == 1 { throw MVError.proxyRequiresBrowserLogin }
        }
        let ledger = makeTestLedger(transport: transport, clock: clock)

        ledger.enqueue(request(.flag, 1))
        let recheck = clock.now.addingTimeInterval(MVIntentLedger.Timing().holdRecheck)
        await waitUntil { ledger.isHeld && clock.hasSleeper(endingAt: recheck) }
        clock.advance(by: MVIntentLedger.Timing().holdRecheck)
        await waitUntil { ledger.intents.first?.state == .done }

        XCTAssertFalse(ledger.isHeld)
        XCTAssertEqual(transport.calls.count, 2)
    }

    // MARK: - Destroying folders

    func testAFolderIsNotDestroyedWhileActionsOnItsAccountAreOnTheirWay() async throws {
        let gate = TestGate()
        let transport = RecordingIntentTransport()
        transport.handler = { _ in await gate.wait() }
        let ledger = makeTestLedger(transport: transport)
        MVStubURLProtocol.reset()
        let client = MVApiClient(
            requestFactory: try MVRequestFactory(baseURL: "https://stub.example.com", authProvider: { .none }),
            urlSession: MVStubURLProtocol.makeSession())
        let suite = try XCTUnwrap(UserDefaults(suiteName: "mailboxes-refusal-\(UUID())"))
        let mailboxes = MailboxesStore(
            apiClient: client, ledger: ledger, uiState: MailboxesUIState(defaults: suite),
            diskCache: MailboxesDiskCache(
                directory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)),
            recentViews: MVRecentViewRecord(defaults: suite))

        ledger.enqueue(request(.trash, 1))
        XCTAssertNotNil(ledger.folderDestructionRefusal(accountId: testAccount))
        XCTAssertNil(ledger.folderDestructionRefusal(accountId: testUUID(999)), "another account was refused")

        do {
            try await mailboxes.deleteFolder(accountId: testAccount, folderId: testFolder, confirmMessageCount: 3)
            XCTFail("a folder was deleted while an action on its account was on its way")
        } catch {
            XCTAssertEqual((error as? MVError)?.isAuthenticationFailure, false)
        }
        do {
            _ = try await mailboxes.emptyFolder(
                accountId: testAccount, folderId: testFolder, confirmMessageCount: 3, snapshotAt: Date())
            XCTFail("a folder was emptied while an action on its account was on its way")
        } catch {}
        XCTAssertNil(MVStubURLProtocol.capturedRequest, "the destructive request went out anyway")

        await gate.open()
        await waitUntil { ledger.intents.first?.state == .done }
        XCTAssertNil(ledger.folderDestructionRefusal(accountId: testAccount))
    }

    func testAFailedActionThatMayHaveLandedStillKeepsItsAccountsFoldersSafe() async {
        let transport = RecordingIntentTransport()
        transport.handler = { _ in throw URLError(.timedOut) }
        var timing = MVIntentLedger.Timing()
        timing.maxAttempts = 1
        let ledger = makeTestLedger(transport: transport, timing: timing)

        ledger.enqueue(request(.archive, 1))
        await waitUntil { ledger.intents.first?.state == .failed }

        XCTAssertNotNil(ledger.folderDestructionRefusal(accountId: testAccount))
    }

    func testTheListDoesNotOfferToEmptyItsFolderWhileActionsAreOnTheirWay() async {
        let backend = FakeMailListBackend()
        backend.pageHandler = { _, _ in testPage(testRows(1...2)) }
        let toasts = MVToastStore()
        let ledger = makeTestLedger(
            transport: backend, toasts: toasts, connectivity: TestConnectivity(online: false))
        let store = MVMailListStore(
            scope: .folder(accountId: testAccount, folderId: testFolder), backend: backend, ledger: ledger,
            toasts: toasts, defaults: testDefaults(threaded: false), session: MVListSession())
        await store.start()

        store.perform(.markRead, on: testUUID(1))
        let snapshot = await store.prepareEmptyFolder()

        XCTAssertNil(snapshot)
        XCTAssertEqual(backend.selectionFilters, [])
        XCTAssertEqual(toasts.current?.variant, .error)
    }
}
