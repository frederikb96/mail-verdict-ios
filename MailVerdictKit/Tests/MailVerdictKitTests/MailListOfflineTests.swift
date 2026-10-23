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
        _ backend: FakeMailListBackend, cache: MVOfflineCache, toasts: MVToastStore? = nil
    ) -> MVMailListStore {
        MVMailListStore(
            scope: scope, backend: backend, ledger: makeTestLedger(transport: backend), toasts: toasts,
            defaults: testDefaults(threaded: false), session: MVListSession(), offlineCache: cache)
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
