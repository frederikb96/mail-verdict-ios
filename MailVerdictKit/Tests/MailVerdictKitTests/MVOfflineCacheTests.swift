import XCTest

@testable import MailVerdictKit

#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif

/// A clock one second further on at every reading, so recency never ties.
final class SteppingClock: @unchecked Sendable {
    private let lock = NSLock()
    private var current = Date(timeIntervalSince1970: 1_800_000_000)

    func now() -> Date {
        lock.lock()
        defer { lock.unlock() }
        current = current.addingTimeInterval(1)
        return current
    }
}

func makeOfflineCache(budget: MVOfflineCache.Budget = MVOfflineCache.Budget()) -> (MVOfflineCache, URL) {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("offline-\(UUID().uuidString)")
    let clock = SteppingClock()
    return (MVOfflineCache(directory: directory, budget: budget, now: { clock.now() }), directory)
}

func offlineThread(_ id: UUID, html: String = "<p>Body</p>") -> ThreadResponse {
    ThreadResponse(messages: [
        ReaderFixtures.message(
            id: id, from: "Alice <alice@example.org>", to: ["bob@example.org"], subject: "Subject", html: html,
            text: "Body", minutesAgo: 5, isSeen: false)
    ])
}

final class MVOfflineCacheTests: XCTestCase {

    /// The cache writes through the app's own date encoder and reads through its decoder; a model
    /// field that does not survive that trip would open offline as something other than what was
    /// read.
    func testAConversationAndAListReadBackAsTheyWereSaved() async {
        let (cache, _) = makeOfflineCache()
        let id = testUUID(1)
        let thread = offlineThread(id)
        let key = MVOfflineListKey(
            scope: .folder(accountId: testAccount, folderId: testFolder), threaded: true, unreadOnly: false)

        await cache.saveConversation(thread, for: id)
        await cache.saveList(testRows(1...3), hasOlder: false, for: key)

        let conversation = await cache.conversation(for: id)
        XCTAssertEqual(conversation?.thread, thread)
        let list = await cache.list(for: key)
        XCTAssertEqual(list?.rows, testRows(1...3))
        XCTAssertEqual(list?.hasOlder, false)
    }

    /// Grouped and ungrouped rows of one folder are different lists; one must never open as the
    /// other.
    func testAListIsKeptPerGroupingAndFilter() async {
        let (cache, _) = makeOfflineCache()
        let scope = ListScope.folder(accountId: testAccount, folderId: testFolder)
        await cache.saveList(
            testRows(1...2), hasOlder: false, for: MVOfflineListKey(scope: scope, threaded: true, unreadOnly: false))

        let flat = await cache.list(for: MVOfflineListKey(scope: scope, threaded: false, unreadOnly: false))
        let unread = await cache.list(for: MVOfflineListKey(scope: scope, threaded: true, unreadOnly: true))
        XCTAssertNil(flat)
        XCTAssertNil(unread)
    }

    /// Rows beyond the per-list budget are dropped, and the page then says there is more below —
    /// otherwise an offline list would end as though it had no older mail.
    func testATrimmedListSaysItHasOlderRows() async {
        var budget = MVOfflineCache.Budget()
        budget.rowsPerList = 3
        let (cache, _) = makeOfflineCache(budget: budget)
        let key = MVOfflineListKey(
            scope: .folder(accountId: testAccount, folderId: testFolder), threaded: false, unreadOnly: false)

        await cache.saveList(testRows(1...5), hasOlder: false, for: key)

        let list = await cache.list(for: key)
        XCTAssertEqual(list?.rows.map(\.id), testRows(1...3).map(\.id))
        XCTAssertEqual(list?.hasOlder, true)
    }

    /// Opening a saved conversation counts as using it: the one evicted is the least recently
    /// used, not the least recently saved.
    func testEvictionDropsTheLeastRecentlyUsedConversation() async {
        var budget = MVOfflineCache.Budget()
        budget.conversations = 3
        let (cache, _) = makeOfflineCache(budget: budget)
        for n in 1...3 { await cache.saveConversation(offlineThread(testUUID(n)), for: testUUID(n)) }

        _ = await cache.conversation(for: testUUID(1))
        await cache.saveConversation(offlineThread(testUUID(4)), for: testUUID(4))
        await cache.saveConversation(offlineThread(testUUID(5)), for: testUUID(5))

        var kept: [Int] = []
        for n in 1...5 {
            if await cache.conversation(for: testUUID(n)) != nil { kept.append(n) }
        }
        XCTAssertEqual(kept, [1, 4, 5])
    }

    /// The byte budget holds however few conversations there are: a large one pushes older ones
    /// out, and one larger than the whole budget is not kept at all.
    func testTheByteBudgetEvictsOlderConversationsAndRefusesOneTooLargeToFit() async {
        let big = String(repeating: "x", count: 6_000)
        var budget = MVOfflineCache.Budget()
        budget.conversationBytes = 15_000
        let (cache, _) = makeOfflineCache(budget: budget)

        for n in 1...3 { await cache.saveConversation(offlineThread(testUUID(n), html: big), for: testUUID(n)) }
        let oldest = await cache.conversation(for: testUUID(1))
        let newest = await cache.conversation(for: testUUID(3))
        XCTAssertNil(oldest)
        XCTAssertNotNil(newest)

        await cache.saveConversation(
            offlineThread(testUUID(9), html: String(repeating: "y", count: 20_000)), for: testUUID(9))
        let tooLarge = await cache.conversation(for: testUUID(9))
        XCTAssertNil(tooLarge)
    }

    /// A truncated file — the app killed mid-write on a file system without atomic rename, or a
    /// disk error — reads as nothing, is removed, and leaves every other copy readable.
    func testAnUnreadableFileIsDroppedWithoutTakingOthersWithIt() async throws {
        let (cache, directory) = makeOfflineCache()
        await cache.saveConversation(offlineThread(testUUID(1)), for: testUUID(1))
        await cache.saveConversation(offlineThread(testUUID(2)), for: testUUID(2))
        let broken = directory.appendingPathComponent("conversations/\(testUUID(1).uuidString.lowercased()).json")
        XCTAssertTrue(FileManager.default.fileExists(atPath: broken.path), "the file under test is not where expected")
        try Data("{\"version\":1,\"value\":{\"thre".utf8).write(to: broken)

        let corrupt = await cache.conversation(for: testUUID(1))
        let intact = await cache.conversation(for: testUUID(2))
        XCTAssertNil(corrupt)
        XCTAssertFalse(FileManager.default.fileExists(atPath: broken.path))
        XCTAssertNotNil(intact)
    }

    /// A file written by a newer build may mean something this build would misread.
    func testAFileFromANewerFormatIsNotTrusted() async throws {
        let (cache, directory) = makeOfflineCache()
        let key = MVOfflineListKey(
            scope: .folder(accountId: testAccount, folderId: testFolder), threaded: false, unreadOnly: false)
        await cache.saveList(testRows(1...2), hasOlder: false, for: key)
        let file = directory.appendingPathComponent("lists/\(key.fileName)")
        let text = try String(contentsOf: file, encoding: .utf8)
        XCTAssertTrue(text.contains("\"version\":1"), "the format version is not where this test rewrites it")
        try text.replacingOccurrences(of: "\"version\":1", with: "\"version\":99").write(
            to: file, atomically: true, encoding: .utf8)

        let list = await cache.list(for: key)
        XCTAssertNil(list)
    }

    /// Signing out removes the mail, and a save that was already on its way does not bring it back.
    func testDiscardRemovesEverythingAndIgnoresLaterSaves() async {
        let (cache, directory) = makeOfflineCache()
        await cache.saveConversation(offlineThread(testUUID(1)), for: testUUID(1))

        await cache.discard()
        await cache.saveConversation(offlineThread(testUUID(2)), for: testUUID(2))

        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
        let after = await cache.conversation(for: testUUID(2))
        XCTAssertNil(after)
    }
}

final class ServerUnreachableErrorTests: XCTestCase {

    /// What a saved copy may stand in for. A refusal or a missing message must never be answered
    /// with a copy: that would show deleted mail, or mail a rejected credential may not read.
    func testOnlyAMissingServerCountsAsUnreachable() {
        XCTAssertTrue(URLError(.notConnectedToInternet).mvIsServerUnreachable)
        XCTAssertTrue(URLError(.cannotConnectToHost).mvIsServerUnreachable)
        XCTAssertTrue(URLError(.timedOut).mvIsServerUnreachable)
        XCTAssertTrue(MVError.http(statusCode: 502, reason: "Bad Gateway").mvIsServerUnreachable)
        XCTAssertTrue(MVError.detail("starting", statusCode: 503).mvIsServerUnreachable)

        XCTAssertFalse(MVError.detail("Message not found", statusCode: 404).mvIsServerUnreachable)
        XCTAssertFalse(MVError.http(statusCode: 401, reason: "Unauthorized").mvIsServerUnreachable)
        XCTAssertFalse(MVError.http(statusCode: 500, reason: "Internal Server Error").mvIsServerUnreachable)
        XCTAssertFalse(MVError.proxyRequiresBrowserLogin.mvIsServerUnreachable)
        XCTAssertFalse(URLError(.cancelled).mvIsServerUnreachable)
        XCTAssertFalse(URLError(.serverCertificateUntrusted).mvIsServerUnreachable)
    }
}
