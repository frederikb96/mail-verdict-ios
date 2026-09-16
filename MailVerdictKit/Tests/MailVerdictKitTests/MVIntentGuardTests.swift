import XCTest

@testable import MailVerdictKit

/// Actions that move mail name the folder they saw each message in, so one sent late — or an undo
/// — never pulls a message out of wherever it was filed since.
@MainActor
final class MVIntentGuardTests: XCTestCase {
    private let archiveFolder = testUUID(701)
    private let elsewhere = testUUID(702)
    private let scope = MVProjectionScope(folderIds: [testFolder], threaded: false)

    private func request(_ action: MVBulkAction, _ n: Int) -> MVIntentRequest {
        MVIntentRequest(
            accountId: testAccount, action: action, messageIds: [testUUID(n)],
            originFolderIds: [testUUID(n): testFolder], snapshots: [testRow(n)])
    }

    func testAMovingActionExpectsTheFolderItWasTakenFromAndAStarDoesNot() async {
        let transport = RecordingIntentTransport()
        let ledger = makeTestLedger(transport: transport)

        ledger.enqueue(request(.archive, 1))
        ledger.enqueue(request(.flag, 2))
        await waitUntil { ledger.intents.allSatisfy { $0.state == .done } }

        XCTAssertEqual(transport.expected, [[testUUID(1): testFolder], [:]])
    }

    /// Rescued from Trash on another device before a queued trash went out: the server leaves it
    /// alone, and so does the phone — the row is back, nothing is retried, and the person is told.
    func testAnActionTheServerDidNotApplyRetiresAndSaysSo() async {
        let toasts = MVToastStore()
        let transport = RecordingIntentTransport()
        transport.applied = false
        let ledger = makeTestLedger(transport: transport, toasts: toasts)
        var outcome: MVIntentOutcome?

        ledger.enqueue(request(.trash, 1)) { outcome = $0 }
        await waitUntil { outcome != nil }

        XCTAssertEqual(outcome, .notApplied)
        XCTAssertTrue(ledger.intents.isEmpty)
        XCTAssertEqual(toasts.current?.message, "Did not move to trash — the message had already moved")
        XCTAssertNil(toasts.current?.actionTitle, "a guard miss offered a retry")
        XCTAssertEqual(
            ledger.project(testRows(1...2), scope: scope).map(\.id), [testUUID(1), testUUID(2)])
    }

    func testUndoExpectsTheMessageWhereTheServerFiledItAndSaysWhenItHasMovedOn() async {
        let toasts = MVToastStore()
        let transport = RecordingIntentTransport()
        transport.filedFolder = archiveFolder
        let ledger = makeTestLedger(transport: transport, toasts: toasts)

        let id = ledger.enqueue(request(.archive, 1))
        await waitUntil { ledger.intents.first?.state == .done }
        XCTAssertEqual(ledger.intents.first?.filedFolderIds, [testUUID(1): archiveFolder])
        transport.applied = false
        ledger.undo([id])
        await waitUntil { transport.calls.count == 2 && ledger.intents.count == 1 }

        XCTAssertEqual(transport.calls, ["archive 1", "move 1"])
        XCTAssertEqual(transport.expected.last, [testUUID(1): archiveFolder])
        XCTAssertEqual(toasts.current?.message, "Nothing to undo — the message is no longer where the action left it")
    }

    func testABulkActionExpectsEveryFolderAndStopsExpandingAtWhatWasSeen() async {
        let transport = RecordingIntentTransport()
        let ledger = makeTestLedger(transport: transport)
        let seen = testReceivedBase.addingTimeInterval(-30)

        ledger.enqueue(
            MVIntentRequest(
                accountId: testAccount, action: .trash, messageIds: [testUUID(1), testUUID(2)],
                delivery: .bulk(expandThreads: true),
                originFolderIds: [testUUID(1): testFolder, testUUID(2): elsewhere], seenThrough: seen))
        ledger.enqueue(
            MVIntentRequest(
                accountId: testAccount, action: .markRead, messageIds: [testUUID(3)],
                delivery: .bulk(expandThreads: true),
                originFolderIds: [testUUID(3): testFolder], seenThrough: seen))
        await waitUntil { ledger.intents.allSatisfy { $0.state == .done } }

        let trash = transport.bulkRequests.first
        XCTAssertEqual(
            trash?.expectedFolderIds,
            [testUUID(1).uuidString.lowercased(): testFolder, testUUID(2).uuidString.lowercased(): elsewhere])
        XCTAssertEqual(trash?.expandThreadsThrough, seen)
        XCTAssertNil(transport.bulkRequests.last?.expectedFolderIds, "a read change was guarded to a folder")
    }

    func testABulkActionEveryMessageOfWhichWasSkippedIsNotApplied() async {
        let transport = SkippingBulkTransport(skipped: [testUUID(1), testUUID(2)], target: archiveFolder)
        let ledger = makeTestLedger(transport: transport)
        var outcome: MVIntentOutcome?

        ledger.enqueue(
            MVIntentRequest(
                accountId: testAccount, action: .archive, messageIds: [testUUID(1), testUUID(2)],
                delivery: .bulk(expandThreads: false),
                originFolderIds: [testUUID(1): testFolder, testUUID(2): testFolder])
        ) { outcome = $0 }
        await waitUntil { outcome != nil }

        XCTAssertEqual(outcome, .notApplied)
    }

    func testABulkActionRecordsWhereItFiledWhatItDidNotSkip() async {
        let transport = SkippingBulkTransport(skipped: [testUUID(2)], target: archiveFolder)
        let ledger = makeTestLedger(transport: transport)

        ledger.enqueue(
            MVIntentRequest(
                accountId: testAccount, action: .archive, messageIds: [testUUID(1), testUUID(2)],
                delivery: .bulk(expandThreads: false),
                originFolderIds: [testUUID(1): testFolder, testUUID(2): testFolder]))
        await waitUntil { ledger.intents.first?.state == .done }

        XCTAssertEqual(ledger.intents.first?.filedFolderIds, [testUUID(1): archiveFolder])
    }

    func testTheGuardFieldsGoOnTheWireAsTheServerReadsThem() throws {
        let key = testUUID(1)
        let bulk = BulkActionRequest(
            action: .trash, ids: [key], expectedFolderIds: [key: testFolder],
            expandThreadsThrough: testReceivedBase)
        let json = try XCTUnwrap(
            JSONSerialization.jsonObject(with: JSONEncoder.mvDefault.encode(bulk)) as? [String: Any])
        let expected = try XCTUnwrap(json["expected_folder_ids"] as? [String: String])

        XCTAssertEqual(expected.keys.first, key.uuidString.lowercased())
        XCTAssertEqual(expected.values.first.flatMap(UUID.init(uuidString:)), testFolder)
        XCTAssertNotNil(json["expand_threads_through"])

        let olderServer = Data(#"{"success":true,"action":"archive","message_id":"\#(key.uuidString)"}"#.utf8)
        let response = try JSONDecoder.mvDefault.decode(MessageActionResponse.self, from: olderServer)
        XCTAssertTrue(response.applied, "a server without the guard reads as not having applied anything")
    }

    /// Rows from two pages: the conversations expand through the newer page's read, so a member
    /// mirrored before either read — whatever its own date — goes with them.
    func testABulkConversationActionExpandsThroughTheNewestReadItsRowsCameFrom() async {
        let backend = FakeMailListBackend()
        let firstRead = testReceivedBase.addingTimeInterval(600)
        let laterRead = testReceivedBase.addingTimeInterval(900)
        backend.pageHandler = { cursor, _ in
            if case .olderThan = cursor {
                return MessageListResponse(
                    messages: [testRow(3), testRow(4)], hasMore: false, nextCursor: nil, asOf: laterRead)
            }
            return MessageListResponse(messages: testRows(1...2), hasMore: true, nextCursor: nil, asOf: firstRead)
        }
        let ledger = makeTestLedger(transport: backend)
        let store = MVMailListStore(
            scope: .folder(accountId: testAccount, folderId: testFolder), backend: backend, ledger: ledger, toasts: nil,
            defaults: testDefaults(threaded: true), session: MVListSession())
        await store.start()
        await store.loadOlder()

        store.toggleSelection(of: testUUID(1))
        store.toggleSelection(of: testUUID(3))
        await store.performBulk(.archive)
        await waitUntil { backend.bulkRequests.count == 1 }

        XCTAssertEqual(backend.bulkRequests.first?.1.expandThreadsThrough, laterRead)
        XCTAssertEqual(backend.bulkRequests.first?.1.expectedFolderIds?.count, 2)
    }

    /// An older server reads no clock with its pages: the conversation expands in full rather than
    /// through a row's own time, which would leave older-dated members behind.
    func testABulkConversationActionFromPagesWithoutAReadClockIsNotBounded() async {
        let backend = FakeMailListBackend()
        backend.pageHandler = { _, _ in
            testPage([testRow(1, mirroredAt: testReceivedBase.addingTimeInterval(120)), testRow(2), testRow(3)])
        }
        let ledger = makeTestLedger(transport: backend)
        let store = MVMailListStore(
            scope: .folder(accountId: testAccount, folderId: testFolder), backend: backend, ledger: ledger, toasts: nil,
            defaults: testDefaults(threaded: true), session: MVListSession())
        await store.start()

        store.toggleSelection(of: testUUID(1))
        store.toggleSelection(of: testUUID(2))
        await store.performBulk(.archive)
        await waitUntil { backend.bulkRequests.count == 1 }

        XCTAssertNil(backend.bulkRequests.first?.1.expandThreadsThrough)
    }
}

/// Answers every bulk action as having skipped `skipped` and filed the rest into `target`.
final class SkippingBulkTransport: MVIntentTransport, @unchecked Sendable {
    private let skipped: [UUID]
    private let target: UUID

    init(skipped: [UUID], target: UUID) {
        self.skipped = skipped
        self.target = target
    }

    func deliverMessageAction(
        messageId: UUID, action: MVMessageAction, targetFolderId: UUID?, expectedFolderId: UUID?, idempotencyKey: UUID,
        timeout: TimeInterval
    ) async throws -> MessageActionResponse {
        MessageActionResponse(success: true, action: action.rawValue, messageId: messageId, message: nil)
    }

    func deliverBulkAction(
        accountId: UUID, request: BulkActionRequest, timeout: TimeInterval
    ) async throws -> BulkActionResponse {
        let ids = request.ids ?? []
        return BulkActionResponse(
            success: true, action: request.action.rawValue, affectedCount: ids.filter { !skipped.contains($0) }.count,
            targetFolderId: target, skippedIds: skipped)
    }

    func fetchConversation(messageId: UUID, timeout: TimeInterval) async throws -> ThreadResponse {
        ThreadResponse(messages: [])
    }

    func fetchMessageState(messageId: UUID, includeFlags: Bool, timeout: TimeInterval) async throws -> MVMessageState? {
        nil
    }

    func fetchFolders(accountId: UUID, timeout: TimeInterval) async throws -> [FolderResponse] {
        testRoleFolderList(accountId: accountId)
    }
}
