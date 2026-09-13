import Foundation
import XCTest

@testable import MailVerdictKit

/// A readable, deterministic id: `testUUID(7)` is `00000000-0000-0000-0000-000000000007`.
func testUUID(_ n: Int) -> UUID {
    let digits = String(n)
    return UUID(uuidString: "00000000-0000-0000-0000-" + String(repeating: "0", count: 12 - digits.count) + digits)!
}

let testAccount = testUUID(900_001)
let testFolder = testUUID(900_002)
let testReceivedBase = Date(timeIntervalSince1970: 1_780_000_000)

/// Row `n` of a newest-first list: a larger `n` is older, so `rows(1...5)` is already in order.
func testRow(
    _ n: Int, account: UUID = testAccount, folder: UUID = testFolder, thread: UUID? = nil, seen: Bool = false,
    unreadInThread: Int? = nil, mirroredAt: Date? = nil
) -> MessageSummary {
    MessageSummary(
        id: testUUID(n), accountId: account, folderId: folder, threadId: thread ?? testUUID(500_000 + n),
        subject: "Subject \(n)", fromAddr: "Sender \(n) <sender\(n)@example.com>", toAddrs: nil,
        receivedAt: testReceivedBase.addingTimeInterval(-Double(n) * 60), isSeen: seen, snippet: "Snippet \(n)",
        unreadInThread: unreadInThread, mirroredAt: mirroredAt ?? testReceivedBase
    )
}

func testRows(_ range: ClosedRange<Int>, seen: Bool = false) -> [MessageSummary] {
    range.map { testRow($0, seen: seen) }
}

func testPage(
    _ rows: [MessageSummary], hasMore: Bool = false, hasMoreNewer: Bool = false
) -> MessageListResponse {
    MessageListResponse(messages: rows, hasMore: hasMore, nextCursor: nil, hasMoreNewer: hasMoreNewer)
}

func testDefaults(threaded: Bool) -> UserDefaults {
    let defaults = UserDefaults(suiteName: "mail-list-tests-\(UUID().uuidString)")!
    MVListPreferences.setThreaded(threaded, defaults: defaults)
    return defaults
}

/// Holds a fake response until a test lets it through — the only way to put an optimistic
/// action in the gap between a request leaving and its response landing.
actor TestGate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        if isOpen { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func open() {
        isOpen = true
        for waiter in waiters { waiter.resume() }
        waiters = []
    }
}

/// Waits for the condition the next assertion checks, failing rather than hanging.
@MainActor
func waitUntil(
    _ condition: () -> Bool, timeout: TimeInterval = 3, file: StaticString = #filePath, line: UInt = #line
) async {
    let deadline = Date().addingTimeInterval(timeout)
    while !condition() {
        if Date() > deadline {
            XCTFail("condition not met within \(timeout)s", file: file, line: line)
            return
        }
        try? await Task.sleep(nanoseconds: 5_000_000)
    }
}

/// A backend double for `MVMailListStore`. Every call is recorded; responses come from
/// handlers a test replaces. Lock-protected rather than an actor so a test configures it
/// synchronously.
final class FakeMailListBackend: MVMailListBackend, @unchecked Sendable {
    typealias PageHandler = @Sendable (MVListCursor, Int) async throws -> MessageListResponse
    typealias BulkHandler = @Sendable (UUID, BulkActionRequest) async throws -> BulkActionResponse

    private let lock = NSLock()
    private var _pageHandler: PageHandler = { _, _ in testPage([]) }
    private var _bulkHandler: BulkHandler = { _, request in
        BulkActionResponse(success: true, action: request.action.rawValue, affectedCount: request.ids?.count ?? 0)
    }
    private var _cursors: [MVListCursor] = []
    private var _messageActions: [(UUID, MVMessageAction, UUID?)] = []
    private var _messageActionError: Error?
    private var _bulkRequests: [(UUID, BulkActionRequest)] = []
    private var _selectionFilters: [MVSelectionFilter] = []
    private var _filterQueries: [String] = []
    private var _filterResults: [SearchResult] = []
    private var _locations: [UUID: MessageLocation] = [:]

    private func locked<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }

    var pageHandler: PageHandler {
        get { locked { _pageHandler } }
        set { locked { _pageHandler = newValue } }
    }
    var bulkHandler: BulkHandler {
        get { locked { _bulkHandler } }
        set { locked { _bulkHandler = newValue } }
    }
    var messageActionError: Error? {
        get { locked { _messageActionError } }
        set { locked { _messageActionError = newValue } }
    }
    var filterResults: [SearchResult] {
        get { locked { _filterResults } }
        set { locked { _filterResults = newValue } }
    }
    var locations: [UUID: MessageLocation] {
        get { locked { _locations } }
        set { locked { _locations = newValue } }
    }
    var cursors: [MVListCursor] { locked { _cursors } }
    var messageActions: [(UUID, MVMessageAction, UUID?)] { locked { _messageActions } }
    var bulkRequests: [(UUID, BulkActionRequest)] { locked { _bulkRequests } }
    var selectionFilters: [MVSelectionFilter] { locked { _selectionFilters } }
    var filterQueries: [String] { locked { _filterQueries } }

    func fetchListPage(
        scope: ListScope, threaded: Bool, unreadOnly: Bool, cursor: MVListCursor, limit: Int
    ) async throws -> MessageListResponse {
        let handler = locked {
            _cursors.append(cursor)
            return _pageHandler
        }
        return try await handler(cursor, limit)
    }

    /// Runs before a filter page is answered — a test holds a query open here, or fails it.
    var filterDelay: (@Sendable (String) async throws -> Void)? {
        get { locked { _filterDelay } }
        set { locked { _filterDelay = newValue } }
    }
    private var _filterDelay: (@Sendable (String) async throws -> Void)?

    func fetchFilterPage(
        query: String, accountId: UUID?, folderIds: [UUID], unreadOnly: Bool, before: UUID?, limit: Int
    ) async throws -> SearchResponse {
        let (results, delay) = locked {
            _filterQueries.append(query)
            return (_filterResults, _filterDelay)
        }
        try await delay?(query)
        return SearchResponse(results: results, hasMore: false, nextCursor: nil, query: query, total: results.count)
    }

    func fetchLocation(messageId: UUID) async throws -> MessageLocation {
        guard let location = locked({ _locations[messageId] }) else {
            throw MVError.detail("Message not found", statusCode: 404)
        }
        return location
    }

    func fetchThread(messageId: UUID) async throws -> ThreadResponse {
        ThreadResponse(messages: [])
    }

    func sendMessageAction(messageId: UUID, action: MVMessageAction, targetFolderId: UUID?) async throws {
        let error = locked {
            _messageActions.append((messageId, action, targetFolderId))
            return _messageActionError
        }
        if let error { throw error }
    }

    func sendBulkAction(accountId: UUID, request: BulkActionRequest) async throws -> BulkActionResponse {
        let handler = locked {
            _bulkRequests.append((accountId, request))
            return _bulkHandler
        }
        return try await handler(accountId, request)
    }

    func fetchSelectionSnapshot(
        accountId: UUID, folderId: UUID, filter: MVSelectionFilter
    ) async throws -> SelectionSnapshotResponse {
        locked { _selectionFilters.append(filter) }
        return SelectionSnapshotResponse(snapshotAt: testReceivedBase, count: 42)
    }

    func sendVerdictFeedback(messageId: UUID, accountId: UUID, isSpam: Bool) async throws {}
    func requestSync(accountId: UUID) async throws {}
    func fetchFolders(accountId: UUID) async throws -> [FolderResponse] { [] }
    func fetchFolderOrder(accountId: UUID) async throws -> FolderOrderResponse { FolderOrderResponse(folders: []) }
    func fetchAccounts() async throws -> [AccountResponse] { [] }
    func fetchSyncStatus(accountId: UUID) async throws -> SyncStatusResponse {
        throw MVError.detail("unused", statusCode: 404)
    }
    func fetchUnifiedViews() async throws -> [UnifiedFolderResponse] { [] }
    func fetchDeadOutbox() async throws -> [OutboxResponse] { [] }
    func fetchContactPhotoIndex(accountId: UUID) async throws -> ContactPhotoIndexResponse {
        ContactPhotoIndexResponse(byEmail: [:])
    }
}
