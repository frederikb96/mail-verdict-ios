import XCTest

@testable import MailVerdictKit

@MainActor
final class MVMailListStoreTests: XCTestCase {

    private let scope = ListScope.folder(accountId: testAccount, folderId: testFolder)

    private func makeStore(
        _ backend: FakeMailListBackend, threaded: Bool = false, unreadOnly: Bool = false, around: UUID? = nil,
        toasts: MVToastStore? = nil, ledger: MVIntentLedger? = nil
    ) -> MVMailListStore {
        let session = MVListSession()
        session.setUnreadOnly(unreadOnly, for: scope)
        return MVMailListStore(
            scope: scope, aroundMessageId: around, backend: backend,
            ledger: ledger ?? makeTestLedger(transport: backend, toasts: toasts), toasts: toasts,
            defaults: testDefaults(threaded: threaded), session: session
        )
    }

    /// Grouped by conversation the server centres on the conversation's own row, a different id
    /// from the message asked for — landing on the id itself would silently never happen.
    func testAThreadedAroundLandingRevealsTheConversationRow() async {
        let conversation = testUUID(777)
        let target = testUUID(99)
        let backend = FakeMailListBackend()
        backend.pageHandler = { _, _ in
            testPage([testRow(1), testRow(2, thread: conversation), testRow(3)], hasMore: true, hasMoreNewer: true)
        }
        backend.locations = [
            target: MessageLocation(id: target, accountId: testAccount, folderId: testFolder, threadId: conversation)
        ]
        let store = makeStore(backend, threaded: true, around: target)

        await store.start()

        XCTAssertEqual(backend.cursors.first, .around(target))
        XCTAssertEqual(store.consumeLanding(), .revealInUpperThird(testUUID(2)))
        XCTAssertTrue(store.hasNewer)
    }

    func testAnAroundTargetThatIsNotInTheListLandsAtTheNewestEdge() async {
        let backend = FakeMailListBackend()
        backend.pageHandler = { cursor, _ in
            if case .around = cursor { throw MVError.detail("Message is not a member of this list", statusCode: 404) }
            return testPage(testRows(1...3))
        }
        let store = makeStore(backend, around: testUUID(99))

        await store.start()

        XCTAssertEqual(backend.cursors, [.around(testUUID(99)), .newest])
        XCTAssertEqual(store.rowIds, testRows(1...3).map(\.id))
        XCTAssertEqual(store.phase, .loaded)
        XCTAssertNil(store.consumeLanding())
    }

    func testAFailedArchivePutsTheRowBackInItsPlace() async {
        let backend = FakeMailListBackend()
        backend.pageHandler = { _, _ in testPage(testRows(1...5)) }
        backend.messageActionError = MVError.detail("Target folder does not exist", statusCode: 409)
        let toasts = MVToastStore()
        let store = makeStore(backend, toasts: toasts)
        await store.start()

        store.perform(.archive, on: testUUID(3))

        XCTAssertFalse(store.rowIds.contains(testUUID(3)))
        await waitUntil { store.rowIds.count == 5 }
        XCTAssertEqual(store.rowIds, testRows(1...5).map(\.id))
        XCTAssertEqual(toasts.current?.variant, .error)
    }

    /// A refresh whose request left before an archive reached the server lands after the server
    /// had it, carrying the row. The row stays out: the archive still applies over a read older
    /// than itself.
    func testARefreshReadBeforeAnArchiveLandedNeverPutsTheRowBack() async {
        let staleGate = TestGate()
        let freshGate = TestGate()
        let backend = FakeMailListBackend()
        let calls = CallCounter()
        backend.pageHandler = { _, _ in
            switch calls.next() {
            case 1: return testPage(testRows(1...5))
            case 2:
                await staleGate.wait()
                return testPage(testRows(1...5))
            default:
                await freshGate.wait()
                return testPage([testRow(1), testRow(2), testRow(4), testRow(5)])
            }
        }
        let ledger = makeTestLedger(transport: backend)
        let store = makeStore(backend, ledger: ledger)
        await store.start()

        store.requestRefresh()
        await waitUntil { backend.cursors.count == 2 }
        store.perform(.archive, on: testUUID(3))
        XCTAssertFalse(store.rowIds.contains(testUUID(3)))
        await waitUntil { ledger.intents.first?.state == .done }
        await staleGate.open()
        await waitUntil { backend.cursors.count == 3 }

        XCTAssertFalse(store.rowIds.contains(testUUID(3)))

        await freshGate.open()
        await store.refresh()
        XCTAssertEqual(store.rowIds, [testUUID(1), testUUID(2), testUUID(4), testUUID(5)])
    }

    /// An archive leaves the ledger while the list still holds a read from before it — the refresh
    /// its settling asked for has not answered. The row stays out for good.
    func testARowStaysOutWhenItsArchiveRetiresBeforeTheListReadsAgain() async {
        let refreshGate = TestGate()
        let backend = FakeMailListBackend()
        let calls = CallCounter()
        backend.pageHandler = { _, _ in
            if calls.next() == 1 { return testPage(testRows(1...3)) }
            await refreshGate.wait()
            return testPage([testRow(1), testRow(3)])
        }
        let clock = TestIntentClock()
        let ledger = makeTestLedger(transport: backend, clock: clock)
        let store = makeStore(backend, ledger: ledger)
        await store.start()

        store.perform(.archive, on: testUUID(2))
        await waitUntil { ledger.intents.first?.state == .done }
        await waitUntil { backend.cursors.count == 2 && clock.sleeperCount == 1 }
        clock.advance(by: MVIntentLedger.Timing().doneRetention)
        await waitUntil { ledger.intents.isEmpty }

        XCTAssertEqual(store.rowIds, [testUUID(1), testUUID(3)])
        await refreshGate.open()
    }

    /// Reading a row while only unread mail is listed must not snatch it away on the next
    /// refresh, which no longer returns it.
    func testARowReadInTheUnreadListStaysThroughARefresh() async {
        let backend = FakeMailListBackend()
        let calls = CallCounter()
        backend.pageHandler = { _, _ in
            calls.next() == 1
                ? testPage(testRows(1...4)) : testPage([testRow(1), testRow(3), testRow(4)])
        }
        let store = makeStore(backend, unreadOnly: true)
        await store.start()

        store.perform(.markRead, on: testUUID(2))
        await waitUntil { backend.messageActions.count == 1 }
        await store.refresh()

        XCTAssertEqual(store.rowIds, testRows(1...4).map(\.id))
        XCTAssertEqual(store.row(id: testUUID(2))?.isSeen, true)
    }

    /// The list controller restores its saved position when an identity it has seen comes back;
    /// clearing the quick filter has to return exactly the unfiltered identity for that to work.
    func testClearingTheQuickFilterReturnsTheUnfilteredRowsAndIdentity() async {
        let backend = FakeMailListBackend()
        backend.pageHandler = { _, _ in testPage(testRows(1...5), hasMore: true) }
        backend.filterResults = [
            SearchResult(
                id: testUUID(40), accountId: testAccount, folderId: testFolder, threadId: testUUID(41), subject: "Hit",
                fromAddr: nil, toAddrs: nil, receivedAt: testReceivedBase, snippet: nil, mirroredAt: testReceivedBase
            )
        ]
        let store = makeStore(backend)
        await store.start()
        let unfilteredIdentity = store.identity

        await store.applyFilter(query: "invoice")
        XCTAssertEqual(store.identity.filterQuery, "invoice")
        XCTAssertEqual(store.rowIds, [testUUID(40)])

        await store.applyFilter(query: "")
        XCTAssertEqual(store.identity, unfilteredIdentity)
        XCTAssertEqual(store.rowIds, testRows(1...5).map(\.id))
        XCTAssertTrue(store.hasOlder)
    }

    /// Each keystroke cancels the filter request still in flight; that cancellation is the
    /// store's own doing and must never reach the screen as "Could not filter".
    func testTypingOnWhileAFilterIsInFlightShowsNoError() async {
        let backend = FakeMailListBackend()
        backend.pageHandler = { _, _ in testPage(testRows(1...5)) }
        backend.filterDelay = { query in
            guard query == "in" else { return }
            do {
                try await Task.sleep(nanoseconds: 10_000_000_000)
            } catch {
                // What URLSession throws for a cancelled task, rather than CancellationError.
                throw URLError(.cancelled)
            }
        }
        let toasts = MVToastStore()
        let store = makeStore(backend, toasts: toasts)
        await store.start()

        store.setFilterText("in")
        await waitUntil { backend.filterQueries == ["in"] }
        store.setFilterText("inv")
        await waitUntil { store.identity.filterQuery == "inv" }

        XCTAssertEqual(backend.filterQueries, ["in", "inv"])
        XCTAssertNil(toasts.current)
        XCTAssertFalse(store.isFilterLoading)
    }

    /// Typing one character too many and deleting it again returns to a query already on screen
    /// while the longer one is still in flight; its late answer must not replace the rows.
    func testALateAnswerForAQueryTypedAwayFromDoesNotReplaceTheRows() async {
        let gate = TestGate()
        let backend = FakeMailListBackend()
        backend.pageHandler = { _, _ in testPage(testRows(1...5)) }
        backend.filterResults = [
            SearchResult(
                id: testUUID(40), accountId: testAccount, folderId: testFolder, threadId: testUUID(41), subject: "Hit",
                fromAddr: nil, toAddrs: nil, receivedAt: testReceivedBase, snippet: nil, mirroredAt: testReceivedBase
            )
        ]
        let store = makeStore(backend)
        await store.start()
        await store.applyFilter(query: "ab")
        let shown = store.identity
        backend.filterDelay = { query in if query == "abc" { await gate.wait() } }

        async let longer: Void = store.applyFilter(query: "abc")
        await waitUntil { backend.filterQueries == ["ab", "abc"] }
        await store.applyFilter(query: "ab")
        await gate.open()
        await longer

        XCTAssertEqual(store.identity, shown)
        XCTAssertFalse(store.isFilterLoading)
    }

    /// A quick-filter hit's snippet carries the server's `**…**` around the matched terms; shown
    /// raw, the asterisks read as part of the mail.
    func testAQuickFilterHitShowsItsMatchedTermsBoldWithoutMarkers() async throws {
        let backend = FakeMailListBackend()
        backend.pageHandler = { _, _ in testPage(testRows(1...2)) }
        backend.filterResults = [
            SearchResult(
                id: testUUID(40), accountId: testAccount, folderId: testFolder, threadId: testUUID(41), subject: "Hit",
                fromAddr: nil, toAddrs: nil, receivedAt: testReceivedBase, snippet: "the **invoice** is due",
                mirroredAt: testReceivedBase
            )
        ]
        let store = makeStore(backend)
        await store.start()

        await store.applyFilter(query: "invoice")
        let row = try XCTUnwrap(store.row(id: testUUID(40)))
        let segments = store.rowData(for: row).line4

        XCTAssertEqual(segments.filter(\.isBold).map(\.text), ["invoice"])
        XCTAssertFalse(segments.contains { $0.text.contains("**") })
    }

    /// An arrival never enters a window that does not start at the newest message; it is
    /// counted for the capsule, and the jump replaces the window with the newest page.
    func testArrivalsAboveAWindowAwayFromTheNewestEdgeAreCountedNotAdded() async {
        let backend = FakeMailListBackend()
        backend.pageHandler = { cursor, _ in
            switch cursor {
            case .around: return testPage(testRows(20...30), hasMore: true, hasMoreNewer: true)
            case .newerThan: return testPage(testRows(10...29), hasMoreNewer: true)
            default: return testPage(testRows(1...5), hasMore: true)
            }
        }
        let store = makeStore(backend, around: testUUID(25))
        await store.start()
        let before = store.identity

        store.apply([.mailNew(accountId: testAccount, folderId: testFolder, messageId: testUUID(1))])
        await waitUntil { backend.cursors.count == 2 }
        await store.refresh()

        XCTAssertEqual(store.rowIds.first, testUUID(20))
        XCTAssertEqual(store.newMessagesCapsuleCount, 1)

        await store.jumpToLatest()
        XCTAssertNotEqual(store.identity, before)
        XCTAssertEqual(store.rowIds, testRows(1...5).map(\.id))
        XCTAssertFalse(store.hasNewer)
        XCTAssertEqual(store.newMessagesCapsuleCount, 0)
    }

    /// A predicate minted as though the list were unfiltered would act on read mail the
    /// person never saw listed.
    func testSelectAllUnderTheUnreadFilterMintsTheUnreadPredicate() async {
        let backend = FakeMailListBackend()
        backend.pageHandler = { _, _ in testPage(testRows(1...3)) }
        let store = makeStore(backend, unreadOnly: true)
        await store.start()

        await store.selectAll()

        XCTAssertEqual(backend.selectionFilters, [.unread])
        XCTAssertEqual(store.effectiveSelection.predicate?.filter, .unread)
        XCTAssertEqual(store.selectionTitle, "All 42 Unread")
    }

    /// A conversation row stands for messages no row showed; Undo must move all of them back,
    /// so its count comes from what the server says it moved.
    func testArchivingTickedConversationsOffersUndoForEveryMessageMoved() async {
        let backend = FakeMailListBackend()
        backend.pageHandler = { _, _ in testPage(testRows(1...4)) }
        backend.bulkHandler = { _, request in
            BulkActionResponse(
                success: true, action: request.action.rawValue, affectedCount: 3,
                sources: [
                    BulkActionSource(id: testUUID(1), folderId: testFolder),
                    BulkActionSource(id: testUUID(11), folderId: testFolder),
                    BulkActionSource(id: testUUID(2), folderId: testFolder),
                ]
            )
        }
        let toasts = MVToastStore()
        let store = makeStore(backend, threaded: true, toasts: toasts)
        await store.start()

        store.toggleSelection(of: testUUID(1))
        store.toggleSelection(of: testUUID(2))
        await store.performBulk(.archive)

        XCTAssertEqual(store.rowIds, [testUUID(3), testUUID(4)])
        XCTAssertFalse(store.isSelecting)
        await waitUntil { toasts.current?.message == "3 messages archived" }
        XCTAssertEqual(backend.bulkRequests.first?.1.expandThreads, true)
        XCTAssertEqual(backend.bulkRequests.first?.1.ids, [testUUID(1), testUUID(2)])
        XCTAssertEqual(toasts.current?.actionTitle, "Undo")

        toasts.current?.action?()
        await waitUntil { backend.bulkRequests.count == 2 }
        XCTAssertEqual(backend.bulkRequests.last?.1.action, .move)
        XCTAssertEqual(backend.bulkRequests.last?.1.targetFolderId, testFolder)
        XCTAssertEqual(Set(backend.bulkRequests.last?.1.ids ?? []), [testUUID(1), testUUID(11), testUUID(2)])
    }

    /// `perform` maps each UI action to the exact wire action the backend receives — the swipe
    /// sheet and Options menu both funnel through this one call, so a mistake here sends the
    /// wrong IMAP-side effect for every surface at once (an Archive swipe landing in Trash, say).
    func testPerformSendsTheRightWireActionForEachUIAction() async {
        let targetFolder = testUUID(42)
        let moveTarget = MVMoveTarget(
            folder: FolderOrderItem(folderId: targetFolder, imapName: "Projects", displayName: nil, specialUse: nil),
            accountId: testAccount
        )
        let cases: [(action: MVMessageUIAction, target: MVMoveTarget?, wire: MVMessageAction, folder: UUID?)] = [
            (.archive, nil, .archive, nil),
            (.delete, nil, .trash, nil),
            (.moveToJunk, nil, .spam, nil),
            (.star, nil, .flag, nil),
            (.markUnread, nil, .markUnread, nil),
            (.moveTo, moveTarget, .move, targetFolder),
        ]
        for testCase in cases {
            let backend = FakeMailListBackend()
            backend.pageHandler = { _, _ in testPage(testRows(1...3)) }
            let store = makeStore(backend)
            await store.start()

            store.perform(testCase.action, on: testUUID(2), target: testCase.target)
            await waitUntil { backend.messageActions.count == 1 }

            XCTAssertEqual(backend.messageActions.map(\.0), [testUUID(2)], "\(testCase.action)")
            XCTAssertEqual(backend.messageActions.map(\.1), [testCase.wire], "\(testCase.action)")
            XCTAssertEqual(backend.messageActions.map(\.2), [testCase.folder], "\(testCase.action)")
        }
    }

}

/// Counts calls from inside a `@Sendable` handler.
final class CallCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    func next() -> Int {
        lock.lock()
        defer { lock.unlock() }
        count += 1
        return count
    }
}
