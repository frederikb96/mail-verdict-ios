import XCTest

@testable import MailVerdictKit

#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif

@MainActor
final class MailListOfflineTests: XCTestCase {

    private let scope = ListScope.folder(accountId: testAccount, folderId: testFolder)
    private var key: MVOfflineListKey { MVOfflineListKey(scope: scope, threaded: false, unreadOnly: false) }

    private func makeStore(
        _ backend: FakeMailListBackend, cache: MVOfflineCache, toasts: MVToastStore? = nil,
        savedCopyRetryDelays: [TimeInterval] = [60]
    ) -> MVMailListStore {
        MVMailListStore(
            scope: scope, backend: backend, ledger: makeTestLedger(transport: backend), toasts: toasts,
            defaults: testDefaults(threaded: false), session: MVListSession(), offlineCache: cache,
            savedCopyRetryDelays: savedCopyRetryDelays)
    }

    /// Saving runs behind the read that produced it; waits for the page the next assertion needs.
    private func savedPage(_ cache: MVOfflineCache) async -> MVOfflineListPage? {
        for _ in 0..<300 {
            if let page = await cache.list(for: key) { return page }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        return nil
    }

    /// A list read once is kept; opened again with the server unreachable it shows that page rather
    /// than an error, and the moment the live connection is back it is read again and live.
    func testAListOpenedOfflineShowsTheSavedPageThenRefreshesOnReconnect() async {
        let (cache, _) = makeOfflineCache()
        let online = FakeMailListBackend()
        online.pageHandler = { _, _ in testPage(testRows(1...3), hasMore: true) }
        await makeStore(online, cache: cache).start()
        let saved = await savedPage(cache)
        XCTAssertNotNil(saved, "the first read was never saved, so the rest proves nothing")

        let backend = FakeMailListBackend()
        backend.pageHandler = { _, _ in throw URLError(.notConnectedToInternet) }
        let store = makeStore(backend, cache: cache)
        store.setConnected(false)
        await store.start()

        XCTAssertEqual(store.phase, .loaded)
        XCTAssertEqual(store.rowIds, testRows(1...3).map(\.id))
        XCTAssertTrue(store.hasOlder)
        XCTAssertNotNil(store.savedCopyAt)
        XCTAssertNotNil(store.offlineNotice(reachability: .offline))

        backend.pageHandler = { _, _ in testPage([testRow(0)] + testRows(1...3), hasMore: true) }
        store.setConnected(true)

        await waitUntil { store.savedCopyAt == nil }
        XCTAssertEqual(store.rowIds, ([testRow(0)] + testRows(1...3)).map(\.id))
        XCTAssertNil(store.offlineNotice(reachability: .online))
    }

    /// A saved page is of unknown age. Once the server answers, the fresh read replaces it rather
    /// than being spliced over it: a splice would keep saved rows below where the read stopped as
    /// though they were live, and hide every message between the two.
    func testReconnectAfterManyArrivalsReplacesTheSavedPage() async {
        let (cache, _) = makeOfflineCache()
        await cache.saveList(testRows(1000...1099), hasOlder: true, for: key)
        let backend = FakeMailListBackend()
        backend.pageHandler = { _, _ in throw URLError(.notConnectedToInternet) }
        let store = makeStore(backend, cache: cache)
        store.setConnected(false)
        await store.start()
        XCTAssertEqual(store.rowIds.first, testUUID(1000), "the saved page was not shown, so this proves nothing")

        backend.pageHandler = { _, _ in testPage(testRows(1...150), hasMore: true) }
        store.setConnected(true)

        await waitUntil { store.savedCopyAt == nil }
        XCTAssertFalse(store.rowIds.contains(testUUID(1050)), "a saved row is shown as live")
        XCTAssertEqual(store.rowIds.count, 150)
        XCTAssertEqual(store.rowIds.last, testUUID(150))
        XCTAssertTrue(store.hasOlder)
        await store.loadOlder()
        XCTAssertEqual(backend.cursors.last, .olderThan(testUUID(150)), "paging went on below a saved row")
    }

    /// A row read while the unread filter is on stays in view when the saved page is replaced,
    /// as it does through any other refresh: it must not vanish under the reader the moment the
    /// connection returns.
    func testARowReadOfflineUnderTheUnreadFilterSurvivesTheReplacement() async {
        let (cache, _) = makeOfflineCache()
        let unreadKey = MVOfflineListKey(scope: scope, threaded: false, unreadOnly: true)
        await cache.saveList(testRows(1...3), hasOlder: false, for: unreadKey)
        let backend = FakeMailListBackend()
        backend.pageHandler = { _, _ in throw URLError(.notConnectedToInternet) }
        let session = MVListSession()
        session.setUnreadOnly(true, for: scope)
        let store = MVMailListStore(
            scope: scope, backend: backend, ledger: makeTestLedger(transport: backend), toasts: nil,
            defaults: testDefaults(threaded: false), session: session, offlineCache: cache)
        store.setConnected(false)
        await store.start()
        XCTAssertNotNil(store.savedCopyAt, "the saved page was not shown, so this proves nothing")
        store.perform(.markRead, on: testUUID(2))

        backend.pageHandler = { _, _ in testPage([testRow(1), testRow(3)]) }
        store.setConnected(true)

        await waitUntil { store.savedCopyAt == nil }
        XCTAssertEqual(store.rowIds, testRows(1...3).map(\.id))
    }

    /// A list opened around a message (Show in Folder, a notification) is a window in the middle
    /// of the folder. Saved, it would come back offline as the top of the folder.
    func testAWindowAwayFromTheNewestEdgeIsNeverSaved() async {
        let (cache, _) = makeOfflineCache()
        let backend = FakeMailListBackend()
        backend.pageHandler = { _, _ in testPage(testRows(200...210), hasMore: true, hasMoreNewer: true) }
        let store = MVMailListStore(
            scope: scope, aroundMessageId: testUUID(205), backend: backend, ledger: makeTestLedger(transport: backend),
            toasts: nil, defaults: testDefaults(threaded: false), session: MVListSession(), offlineCache: cache)

        await store.start()
        XCTAssertTrue(store.hasNewer, "the window opened at the newest edge, so this proves nothing")
        await store.refresh()
        // An absence: given the time a save takes to land, none did.
        try? await Task.sleep(nanoseconds: 300_000_000)

        let saved = await cache.list(for: key)
        XCTAssertNil(saved)
    }

    /// A read that timed out while the live stream stayed up falls back to the saved page, and no
    /// reconnect follows to replace it. It is read again on a short schedule instead.
    func testASavedPageDrawnWhileConnectedIsReadAgainOnItsOwn() async {
        let (cache, _) = makeOfflineCache()
        await cache.saveList(testRows(1...3), hasOlder: false, for: key)
        let backend = FakeMailListBackend()
        backend.pageHandler = { _, _ in throw URLError(.timedOut) }
        let store = makeStore(backend, cache: cache, savedCopyRetryDelays: [0.05, 0.05, 0.05])
        store.setConnected(true)
        await store.start()
        XCTAssertNotNil(store.savedCopyAt, "the saved page was not shown, so this proves nothing")

        backend.pageHandler = { _, _ in testPage([testRow(0)] + testRows(1...3)) }

        await waitUntil { store.savedCopyAt == nil }
        XCTAssertEqual(store.rowIds.first, testUUID(0))
    }

    /// The schedule is bounded: a server that keeps failing is not asked forever.
    func testTheRetryScheduleRunsOut() async throws {
        let (cache, _) = makeOfflineCache()
        await cache.saveList(testRows(1...3), hasOlder: false, for: key)
        let backend = FakeMailListBackend()
        backend.pageHandler = { _, _ in throw URLError(.timedOut) }
        let store = makeStore(backend, cache: cache, savedCopyRetryDelays: [0.02, 0.02])
        store.setConnected(true)
        await store.start()
        XCTAssertNotNil(store.savedCopyAt, "the saved page was not shown, so this proves nothing")

        try await Task.sleep(nanoseconds: 400_000_000)

        XCTAssertEqual(backend.cursors.count, 3, "\(backend.cursors)")
        XCTAssertNotNil(store.savedCopyAt)
    }

    /// A network loss too short to drop the live stream never arrives as a reconnect; the path
    /// coming back reads a saved page again by itself.
    func testTheNetworkReturningReadsASavedPageAgain() async {
        let (cache, _) = makeOfflineCache()
        await cache.saveList(testRows(1...3), hasOlder: false, for: key)
        let backend = FakeMailListBackend()
        backend.pageHandler = { _, _ in throw URLError(.notConnectedToInternet) }
        let store = makeStore(backend, cache: cache)
        await store.start()
        XCTAssertNotNil(store.savedCopyAt, "the saved page was not shown, so this proves nothing")

        backend.pageHandler = { _, _ in testPage([testRow(0)] + testRows(1...3)) }
        store.networkPathRestored()

        await waitUntil { store.savedCopyAt == nil }
        XCTAssertEqual(store.rowIds.first, testUUID(0))
    }

    /// After a cold launch offline the folders cannot be read; the roles kept on disk still make a
    /// row in Trash offer Delete Forever rather than a second move to Trash.
    func testASavedPageKnowsItsFolderRoles() async {
        let (cache, _) = makeOfflineCache()
        await cache.saveList(testRows(1...2), hasOlder: false, for: key)
        await cache.saveFolderRoles(from: [roleFolder(testFolder, "trash")])
        let backend = FakeMailListBackend()
        backend.pageHandler = { _, _ in throw URLError(.notConnectedToInternet) }
        let store = makeStore(backend, cache: cache)

        await store.start()

        XCTAssertNotNil(store.savedCopyAt, "the saved page was not shown, so this proves nothing")
        XCTAssertEqual(store.row(id: testUUID(1)).map(store.isInTrash), true)
    }

    /// A server that answered — with an error — is not offline: its answer is shown, never an old
    /// copy that could hold mail it has since refused or removed.
    func testAServerErrorIsNotAnsweredWithTheSavedPage() async {
        let (cache, _) = makeOfflineCache()
        let online = FakeMailListBackend()
        online.pageHandler = { _, _ in testPage(testRows(1...3)) }
        await makeStore(online, cache: cache).start()
        let saved = await savedPage(cache)
        XCTAssertNotNil(saved, "nothing was saved, so this proves nothing")

        let backend = FakeMailListBackend()
        backend.pageHandler = { _, _ in throw MVError.http(statusCode: 500, reason: "Internal Server Error") }
        let store = makeStore(backend, cache: cache)
        await store.start()

        guard case .failed = store.phase else { return XCTFail("expected the error, got \(store.phase)") }
        XCTAssertTrue(store.rowIds.isEmpty)
        XCTAssertNil(store.savedCopyAt)
    }

    /// A reload of the list already on screen that cannot reach the server keeps the rows the
    /// reader is looking at; the saved page may be older than they are.
    func testAFailedReloadKeepsTheRowsOnScreenRatherThanTheSavedPage() async {
        let (cache, _) = makeOfflineCache()
        let backend = FakeMailListBackend()
        backend.pageHandler = { _, _ in testPage(testRows(1...3)) }
        let store = makeStore(backend, cache: cache, toasts: MVToastStore())
        await store.start()
        let saved = await savedPage(cache)
        XCTAssertNotNil(saved, "nothing was saved, so this proves nothing")
        backend.pageHandler = { _, _ in testPage([testRow(0)] + testRows(1...3)) }
        await store.refresh()
        XCTAssertEqual(store.rowIds.first, testUUID(0), "the newer row never arrived, so this proves nothing")

        backend.pageHandler = { _, _ in throw URLError(.notConnectedToInternet) }
        await store.jumpToLatest()

        XCTAssertEqual(store.rowIds.first, testUUID(0))
        XCTAssertNil(store.savedCopyAt)
    }

    /// Opened offline with nothing saved, the list fails — and loads by itself once the connection
    /// is back, rather than waiting for a tap on Retry.
    func testAListThatNeverLoadedLoadsOnReconnect() async {
        let (cache, _) = makeOfflineCache()
        let backend = FakeMailListBackend()
        backend.pageHandler = { _, _ in throw URLError(.notConnectedToInternet) }
        let store = makeStore(backend, cache: cache)
        store.setConnected(false)
        await store.start()
        guard case .failed = store.phase else { return XCTFail("expected a failed list, got \(store.phase)") }

        backend.pageHandler = { _, _ in testPage(testRows(1...2)) }
        store.setConnected(true)

        await waitUntil { store.phase == .loaded }
        XCTAssertEqual(store.rowIds, testRows(1...2).map(\.id))
    }

    /// Pull to refresh is asked for; one that cannot reach the server says so instead of ending as
    /// though the list were current.
    func testPullToRefreshOfflineSaysItCouldNotRefresh() async {
        let backend = FakeMailListBackend()
        backend.pageHandler = { _, _ in testPage(testRows(1...2)) }
        let toasts = MVToastStore()
        let (cache, _) = makeOfflineCache()
        let store = makeStore(backend, cache: cache, toasts: toasts)
        await store.start()
        XCTAssertEqual(store.phase, .loaded)

        backend.pageHandler = { _, _ in throw URLError(.notConnectedToInternet) }
        await store.pullToRefresh()

        XCTAssertEqual(
            toasts.current?.message.hasPrefix("Could not refresh"), true, "\(String(describing: toasts.current))")
        XCTAssertEqual(store.rowIds, testRows(1...2).map(\.id))
    }
}
