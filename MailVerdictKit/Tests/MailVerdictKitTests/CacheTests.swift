import Foundation
import XCTest

@testable import MailVerdictKit

/// Counts thread fetches and lets a test hold one open, so a second caller can arrive while the
/// first is still in flight.
private final class ThreadFetchCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var _calls: [UUID] = []
    let gate = TestGate()
    var calls: [UUID] {
        lock.lock()
        defer { lock.unlock() }
        return _calls
    }

    private func record(_ rowId: UUID) {
        lock.lock()
        defer { lock.unlock() }
        _calls.append(rowId)
    }

    func fetch(_ rowId: UUID, messages: [UUID]) async throws -> ThreadResponse {
        record(rowId)
        await gate.wait()
        return ThreadResponse(messages: messages.map { cacheTestMessage($0) })
    }
}

private func cacheTestMessage(_ id: UUID) -> MessageDetail {
    ReaderFixtures.message(
        id: id, from: "Alice <alice@example.org>", to: [], subject: "s", html: "<p>x</p>", text: nil, minutesAgo: 1)
}

@MainActor
final class MVThreadCacheTests: XCTestCase {

    /// A tap arriving while the touch-down prefetch is still in flight must wait for that one
    /// request, never start a second — otherwise prefetching doubles the load it exists to hide.
    func testATapDuringAnUrgentPrefetchJoinsItsRequest() async throws {
        let counter = ThreadFetchCounter()
        let row = testUUID(1)
        let cache = MVThreadCache(fetch: { try await counter.fetch($0, messages: [$0]) })

        cache.prefetchUrgently(row)
        async let opened = cache.thread(for: row)
        await waitUntil { counter.calls.count == 1 }
        await counter.gate.open()
        let thread = try await opened

        XCTAssertEqual(thread.messages.map(\.id), [row])
        XCTAssertEqual(counter.calls, [row])
        XCTAssertNotNil(cache.cached(row), "the prefetched thread was not kept for the reader")
    }

    /// A read-state change on any message of a cached conversation drops it, including a reply
    /// that is not the row's own message.
    func testAChangeToAnyMessageInTheConversationDropsItsCopy() async throws {
        let row = testUUID(1)
        let reply = testUUID(2)
        let other = testUUID(3)
        let cache = MVThreadCache(fetch: { _ in ThreadResponse(messages: []) })
        cache.store(ThreadResponse(messages: [cacheTestMessage(row), cacheTestMessage(reply)]), for: row)
        cache.store(ThreadResponse(messages: [cacheTestMessage(other)]), for: other)

        cache.apply([.mailUpdated(accountId: nil, folderId: nil, messageId: reply, changed: ["is_seen"])])

        XCTAssertNil(cache.cached(row))
        XCTAssertNotNil(cache.cached(other), "an unrelated conversation was dropped too")
    }

    /// A fetch that was in flight when its conversation changed answers from before the change;
    /// it must not become the copy the next open draws.
    func testAFetchInFlightAcrossAChangeIsNotKept() async throws {
        let counter = ThreadFetchCounter()
        let row = testUUID(1)
        let cache = MVThreadCache(fetch: { try await counter.fetch($0, messages: [$0]) })

        cache.prefetchUrgently(row)
        await waitUntil { counter.calls.count == 1 }
        cache.apply([.resync])
        await counter.gate.open()
        _ = try await cache.thread(for: row)

        XCTAssertNil(cache.cached(row))
    }

    func testACopyOlderThanTheLimitIsNotServed() {
        let clock = TestClock()
        let row = testUUID(1)
        let cache = MVThreadCache(fetch: { _ in ThreadResponse(messages: []) }, now: { clock.now })
        cache.store(ThreadResponse(messages: [cacheTestMessage(row)]), for: row)

        clock.advance(by: 11 * 60)

        XCTAssertNil(cache.cached(row))
    }
}

/// A clock a test moves by hand.
final class TestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var current = Date(timeIntervalSince1970: 1_780_000_000)
    var now: Date {
        lock.lock()
        defer { lock.unlock() }
        return current
    }

    func advance(by seconds: TimeInterval) {
        lock.lock()
        current = current.addingTimeInterval(seconds)
        lock.unlock()
    }
}

/// A backend whose folder reads count and can be held open.
private final class CountingReferenceBackend: MVMailListBackend, @unchecked Sendable {
    private let lock = NSLock()
    private var _folderCalls = 0
    let gate = TestGate()
    var folderCalls: Int {
        lock.lock()
        defer { lock.unlock() }
        return _folderCalls
    }

    private func countFolderCall() {
        lock.lock()
        defer { lock.unlock() }
        _folderCalls += 1
    }

    func fetchFolders(accountId: UUID) async throws -> [FolderResponse] {
        countFolderCall()
        await gate.wait()
        return []
    }

    func fetchListPage(
        scope: ListScope, threaded: Bool, unreadOnly: Bool, cursor: MVListCursor, limit: Int
    ) async throws -> MessageListResponse { testPage([]) }
    func fetchFilterPage(
        query: String, accountId: UUID?, folderIds: [UUID], unreadOnly: Bool, before: UUID?, limit: Int
    ) async throws -> SearchResponse {
        SearchResponse(results: [], hasMore: false, nextCursor: nil, query: query, total: 0)
    }
    func fetchLocation(messageId: UUID) async throws -> MessageLocation { throw MVError.transport("unused") }
    func fetchThread(messageId: UUID) async throws -> ThreadResponse { ThreadResponse(messages: []) }
    func sendMessageAction(messageId: UUID, action: MVMessageAction, targetFolderId: UUID?) async throws {}
    func sendBulkAction(accountId: UUID, request: BulkActionRequest) async throws -> BulkActionResponse {
        throw MVError.transport("unused")
    }
    func fetchSelectionSnapshot(
        accountId: UUID, folderId: UUID, filter: MVSelectionFilter
    ) async throws -> SelectionSnapshotResponse { throw MVError.transport("unused") }
    func sendVerdictFeedback(messageId: UUID, accountId: UUID, isSpam: Bool) async throws {}
    func requestSync(accountId: UUID) async throws {}
    func fetchFolderOrder(accountId: UUID) async throws -> FolderOrderResponse { FolderOrderResponse(folders: []) }
    func fetchAccounts() async throws -> [AccountResponse] { [] }
    func fetchSyncStatus(accountId: UUID) async throws -> SyncStatusResponse { throw MVError.transport("unused") }
    func fetchUnifiedViews() async throws -> [UnifiedFolderResponse] { [] }
    func fetchDeadOutbox() async throws -> [OutboxResponse] { [] }
    func fetchContactPhotoIndex(accountId: UUID) async throws -> ContactPhotoIndexResponse {
        ContactPhotoIndexResponse(byEmail: [:])
    }
}

@MainActor
final class MVReferenceCacheTests: XCTestCase {

    /// Several screens opening at once — a list and the reader over it — share one request.
    func testConcurrentReadsOfOneAccountsFoldersShareARequest() async {
        let backend = CountingReferenceBackend()
        let cache = MVReferenceCache(backend: backend)

        async let first = cache.fetchFolders(accountId: testAccount)
        async let second = cache.folders(accountId: testAccount)
        await waitUntil { backend.folderCalls == 1 }
        await backend.gate.open()
        _ = await (first, second)

        XCTAssertEqual(backend.folderCalls, 1)
        XCTAssertNotNil(cache.cachedFolders(accountId: testAccount))
    }

    /// A folder being renamed or created elsewhere must not leave the reader labelling Delete or
    /// Junk from the old list.
    func testAFolderChangeDropsTheCachedFolders() async {
        let backend = CountingReferenceBackend()
        await backend.gate.open()
        let cache = MVReferenceCache(backend: backend)
        _ = await cache.fetchFolders(accountId: testAccount)

        cache.apply([.foldersChanged])

        XCTAssertNil(cache.cachedFolders(accountId: testAccount))
        _ = await cache.folders(accountId: testAccount)
        XCTAssertEqual(backend.folderCalls, 2)
    }
}
