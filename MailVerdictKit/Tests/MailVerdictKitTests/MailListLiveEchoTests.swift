import XCTest

@testable import MailVerdictKit

/// A list re-reads when the server answers an action of its own; the event announcing the same
/// change must not make it read a second time, while another client's change still does.
@MainActor
final class MailListLiveEchoTests: XCTestCase {

    private let scope = ListScope.folder(accountId: testAccount, folderId: testFolder)

    private func makeStore(
        _ backend: FakeMailListBackend, ledger: MVIntentLedger
    ) -> MVMailListStore {
        MVMailListStore(
            scope: scope, backend: backend, ledger: ledger, toasts: nil, defaults: testDefaults(threaded: false),
            session: MVListSession())
    }

    private func settledArchiveOfRow3(_ backend: FakeMailListBackend) async -> (MVMailListStore, TestIntentClock) {
        backend.pageHandler = { _, _ in testPage(testRows(1...5)) }
        let clock = TestIntentClock()
        let store = makeStore(backend, ledger: makeTestLedger(transport: backend, clock: clock))
        await store.start()
        store.perform(.archive, on: testUUID(3))
        await waitUntil { backend.cursors.count == 2 }
        return (store, clock)
    }

    private func event(_ invalidation: MVLiveInvalidation, at arrivedAt: Date) -> MVLiveEvent {
        MVLiveEvent(invalidation, arrivedAt: arrivedAt)
    }

    private func moved(_ n: Int) -> MVLiveInvalidation {
        .mailUpdated(accountId: testAccount, folderId: testUUID(701), messageId: testUUID(n), changed: ["folder_id"])
    }

    func testTheEchoOfAnAnsweredActionDoesNotReadTheListAgain() async {
        let backend = FakeMailListBackend()
        let (store, clock) = await settledArchiveOfRow3(backend)

        store.apply([event(moved(3), at: clock.now)])
        try? await Task.sleep(nanoseconds: 200_000_000)

        XCTAssertEqual(backend.cursors.count, 2, "the settle read plus the start, nothing for the echo")
    }

    func testAnotherClientsChangeStillReadsTheList() async {
        let backend = FakeMailListBackend()
        let (store, clock) = await settledArchiveOfRow3(backend)

        store.apply([event(moved(4), at: clock.now)])

        await waitUntil { backend.cursors.count == 3 }
    }

    func testALateEventForTheSameMessageIsAnotherChangeAndReadsTheList() async {
        let backend = FakeMailListBackend()
        let (store, clock) = await settledArchiveOfRow3(backend)

        store.apply([event(moved(3), at: clock.now.addingTimeInterval(30))])

        await waitUntil { backend.cursors.count == 3 }
    }

    func testAnEventWithoutArrivalTimeReadsTheList() async {
        let backend = FakeMailListBackend()
        let (store, _) = await settledArchiveOfRow3(backend)

        store.apply([moved(3)])

        await waitUntil { backend.cursors.count == 3 }
    }

    // MARK: - Counts

    private func inbox(unread: Int, total: Int) -> FolderResponse {
        FolderResponse(
            id: testFolder, accountId: testAccount, imapName: "INBOX", displayName: nil, specialUse: "inbox",
            mailboxId: nil, backfillTotal: nil, idleStatus: nil, lastSyncedAt: nil, syncError: nil, createdAt: nil,
            unreadCount: unread, totalCount: total)
    }

    /// The title the reader shows ("{N} Messages") and the destructive confirmations read the
    /// folder's counts from the context, which used to be read once and left.
    func testTheFolderCountsFollowMailEvents() async {
        let backend = FakeMailListBackend()
        backend.pageHandler = { _, _ in testPage(testRows(1...5)) }
        backend.folderList = [inbox(unread: 2, total: 5)]
        let store = makeStore(backend, ledger: makeTestLedger(transport: backend))
        await store.start()
        XCTAssertEqual(store.readerTitle, "5 Messages")

        backend.folderList = [inbox(unread: 3, total: 6)]
        store.apply([.mailNew(accountId: testAccount, folderId: testFolder, messageId: testUUID(9))])

        await waitUntil { store.readerTitle == "6 Messages" }
    }

    func testEventsInOtherFoldersAndFlagChangesLeaveTheCountsAlone() async {
        let backend = FakeMailListBackend()
        backend.pageHandler = { _, _ in testPage(testRows(1...5)) }
        let store = makeStore(backend, ledger: makeTestLedger(transport: backend))
        await store.start()
        let fetches = backend.folderFetches

        store.apply([
            .mailNew(accountId: testAccount, folderId: testUUID(701), messageId: testUUID(9)),
            .mailUpdated(accountId: testAccount, folderId: testFolder, messageId: testUUID(1), changed: ["is_flagged"]),
        ])
        try? await Task.sleep(nanoseconds: 200_000_000)

        XCTAssertEqual(backend.folderFetches, fetches)
    }

    /// An answered action's echo is not skipped for the counts: nothing else re-reads them.
    func testTheEchoOfAnOwnActionStillRefreshesTheCounts() async {
        let backend = FakeMailListBackend()
        let (store, clock) = await settledArchiveOfRow3(backend)
        let fetches = backend.folderFetches

        store.apply([event(moved(3), at: clock.now)])

        await waitUntil { backend.folderFetches > fetches }
    }

    /// A sync sends many events; the counts are read one at a time, with one more queued.
    func testABurstOfEventsReadsTheCountsOnceRunningAndOnceQueued() async {
        let backend = FakeMailListBackend()
        backend.pageHandler = { _, _ in testPage(testRows(1...5)) }
        let store = makeStore(backend, ledger: makeTestLedger(transport: backend))
        await store.start()
        let fetches = backend.folderFetches

        for n in 10..<20 {
            store.apply([.mailNew(accountId: testAccount, folderId: testFolder, messageId: testUUID(n))])
        }
        try? await Task.sleep(nanoseconds: 400_000_000)

        XCTAssertLessThanOrEqual(backend.folderFetches - fetches, 2)
        XCTAssertGreaterThanOrEqual(backend.folderFetches - fetches, 1)
    }
}
