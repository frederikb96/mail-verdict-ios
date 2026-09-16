import XCTest

@testable import MailVerdictKit

@MainActor
final class ReaderTestSource: ReaderListSource {
    var rowIds: [UUID]
    var hasOlder: Bool
    var hasNewer = false
    var olderPages: [[UUID]]

    init(rowIds: [UUID], olderPages: [[UUID]] = []) {
        self.rowIds = rowIds
        self.olderPages = olderPages
        self.hasOlder = !olderPages.isEmpty
    }

    func loadOlder() async {
        guard !olderPages.isEmpty else { return }
        rowIds += olderPages.removeFirst()
        hasOlder = !olderPages.isEmpty
    }

    func loadNewer() async {}
}

/// The ids an intent has hidden, as a test sets them.
@MainActor
final class HiddenIds {
    var ids: Set<UUID>
    init(_ ids: Set<UUID>) { self.ids = ids }
}

final class ReaderNeighbourTests: XCTestCase {
    private let ids = (0..<5).map { _ in UUID() }

    /// The plain case, nothing removed and the current row still present: older is the next row
    /// down the list, newer the one above — every paging surface (swipe direction, chevrons,
    /// auto-advance) is specified against this order.
    func testPlainOrderWithNothingRemoved() {
        let found = ReaderNeighbourResolver.neighbours(of: ids[2], rows: ids, previousRows: ids, removed: [])
        XCTAssertEqual(found.older, ids[3])
        XCTAssertEqual(found.newer, ids[1])
    }

    func testRowsTheReaderRemovedAreSkipped() {
        let found = ReaderNeighbourResolver.neighbours(
            of: ids[2], rows: ids, previousRows: ids, removed: [ids[1], ids[3]])
        XCTAssertEqual(found.newer, ids[0])
        XCTAssertEqual(found.older, ids[4])
    }

    func testACurrentRowThatLeftTheListFindsItsNearestSurvivors() {
        let rows = [ids[0], ids[3], ids[4]]
        let found = ReaderNeighbourResolver.neighbours(of: ids[2], rows: rows, previousRows: ids, removed: [])
        XCTAssertEqual(found.newer, ids[0])
        XCTAssertEqual(found.older, ids[3])
    }
}

@MainActor
final class ReaderPagingStoreTests: XCTestCase {
    private let a = UUID()
    private let b = UUID()
    private let c = UUID()

    func testRemovingTheCurrentMessageAdvancesInTheDirectionLastPaged() async {
        let source = ReaderTestSource(rowIds: [a, b, c])
        let store = ReaderPagingStore(openedId: c, source: source)
        XCTAssertTrue(store.move(.newer))
        XCTAssertEqual(store.remove(b), .advance(to: a, direction: .newer))
        XCTAssertEqual(store.currentId, a)
    }

    func testFallsBackToTheOtherSideAtTheEndOfTheList() async {
        let source = ReaderTestSource(rowIds: [a, b, c])
        let store = ReaderPagingStore(openedId: c, source: source)
        XCTAssertEqual(store.remove(c), .advance(to: b, direction: .newer))
    }

    func testRemovingTheOnlyMessageCloses() async {
        let source = ReaderTestSource(rowIds: [a])
        let store = ReaderPagingStore(openedId: a, source: source)
        XCTAssertEqual(store.remove(a), .exhausted)
    }

    func testAHiddenMessageIsSkippedAndANeighbourAgainOnceShown() async {
        let source = ReaderTestSource(rowIds: [a, b, c])
        let hidden = HiddenIds([a])
        let store = ReaderPagingStore(openedId: b, source: source, hiddenIds: { hidden.ids })
        XCTAssertNil(store.newerId)
        hidden.ids = []
        store.refresh()
        XCTAssertEqual(store.newerId, a)
    }

    func testTheEndOfTheLoadedWindowWaitsForTheNextPage() async {
        let source = ReaderTestSource(rowIds: [a, b], olderPages: [[c]])
        let store = ReaderPagingStore(openedId: b, source: source)
        XCTAssertEqual(store.older, .loadingMore)
        await store.loadMoreIfNeeded()
        XCTAssertEqual(store.older, .message(c))
    }

    func testTheListDroppingTheCurrentRowMovesTheReaderOn() async {
        let source = ReaderTestSource(rowIds: [a, b, c])
        let store = ReaderPagingStore(openedId: b, source: source)
        source.rowIds = [a, c]
        XCTAssertEqual(store.refresh(), .advance(to: c, direction: .older))
    }

    /// The list catching up with a removal the reader already closed on is not a second removal —
    /// reporting it would close the reader twice.
    func testTheListDroppingARowTheReaderRemovedItselfIsNotReportedAgain() async {
        let source = ReaderTestSource(rowIds: [a])
        let hidden = HiddenIds([])
        let store = ReaderPagingStore(openedId: a, source: source, hiddenIds: { hidden.ids })
        hidden.ids = [a]
        XCTAssertEqual(store.remove(a), .exhausted)
        source.rowIds = []
        XCTAssertNil(store.refresh())
    }

    func testWithoutASourceThereIsNothingToPageTo() async {
        let store = ReaderPagingStore(openedId: a, source: nil)
        XCTAssertNil(store.older)
        XCTAssertNil(store.newer)
        XCTAssertFalse(store.move(.older))
    }

    /// `ReaderTestSource` above hand-rolls its own `rowIds`, so it cannot catch a regression in
    /// how the real store orders its own — this feeds `MVMailListStore` itself in as the source,
    /// the same object `ReaderSourceRegistry` hands a live reader.
    func testPagesInTheOrderTheRealListStoreGives() async {
        let backend = FakeMailListBackend()
        backend.pageHandler = { _, _ in testPage(testRows(1...5)) }
        let listStore = MVMailListStore(
            scope: .folder(accountId: testAccount, folderId: testFolder), aroundMessageId: nil, backend: backend,
            ledger: makeTestLedger(transport: backend), toasts: nil, defaults: testDefaults(threaded: false),
            session: MVListSession()
        )
        await listStore.start()

        let store = ReaderPagingStore(openedId: testUUID(3), source: listStore)
        XCTAssertEqual(store.olderId, testUUID(4))
        XCTAssertEqual(store.newerId, testUUID(2))
    }
}

final class ZoomEdgeHandoffTests: XCTestCase {

    func testNothingIsPinnedAtRestZoom() {
        XCTAssertEqual(MVZoomEdgeHandoff.pinnedEdges(zoomScale: 1.005, offsetX: 0, minOffsetX: 0, maxOffsetX: 0), [])
    }

    func testPinnedEdgesFollowTheContentOffset() {
        XCTAssertEqual(
            MVZoomEdgeHandoff.pinnedEdges(zoomScale: 2, offsetX: 0, minOffsetX: 0, maxOffsetX: 390), [.leading])
        XCTAssertEqual(
            MVZoomEdgeHandoff.pinnedEdges(zoomScale: 2, offsetX: 390, minOffsetX: 0, maxOffsetX: 390), [.trailing])
        XCTAssertEqual(MVZoomEdgeHandoff.pinnedEdges(zoomScale: 2, offsetX: 200, minOffsetX: 0, maxOffsetX: 390), [])
    }

    func testASmallSidewaysMovementWhileZoomedNeverPages() {
        XCTAssertNil(MVZoomEdgeHandoff.handoff(pinned: [.leading], translationX: 20, translationY: 0))
    }

    func testADragThatBeganAwayFromTheEdgeNeverPages() {
        XCTAssertNil(MVZoomEdgeHandoff.handoff(pinned: [], translationX: 400, translationY: 0))
    }

    func testADragTowardsTheUnpinnedEdgeNeverPages() {
        XCTAssertNil(MVZoomEdgeHandoff.handoff(pinned: [.leading], translationX: -200, translationY: 0))
    }

    func testAMostlyVerticalDragStaysThePagesOwn() {
        XCTAssertNil(MVZoomEdgeHandoff.handoff(pinned: [.leading], translationX: 60, translationY: 60))
    }

    func testADeliberateOvershootFollowsTheFingerAndCanCommit() throws {
        let handoff = try XCTUnwrap(MVZoomEdgeHandoff.handoff(pinned: [.leading], translationX: 150, translationY: 10))
        XCTAssertEqual(handoff.edge, .leading)
        XCTAssertEqual(handoff.distance, 126)
        XCTAssertTrue(MVZoomEdgeHandoff.shouldCommit(distance: 126, velocityX: 0, edge: .leading, pageWidth: 390))
        XCTAssertFalse(MVZoomEdgeHandoff.shouldCommit(distance: 60, velocityX: 0, edge: .leading, pageWidth: 390))
        XCTAssertTrue(MVZoomEdgeHandoff.shouldCommit(distance: 60, velocityX: 700, edge: .leading, pageWidth: 390))
        XCTAssertFalse(MVZoomEdgeHandoff.shouldCommit(distance: 60, velocityX: -700, edge: .leading, pageWidth: 390))
        XCTAssertEqual(MVZoomEdgeHandoff.direction(for: .leading), .newer)
    }
}

final class ReaderAnchorAndReadPolicyTests: XCTestCase {

    func testAnchorKeepsTheSameBlockAtTheSameDistanceAfterARebuild() throws {
        let before = [(id: "m1", top: 0.0), (id: "m2", top: 300.0), (id: "m3", top: 700.0)]
        let anchor = try XCTUnwrap(ReaderScrollAnchor.capture(positions: before, visibleTop: 700, zoomScale: 2))
        XCTAssertEqual(anchor, ReaderScrollAnchor(elementId: "m2", offset: 100))
        let after = [(id: "m0", top: 0.0), (id: "m1", top: 150.0), (id: "m2", top: 400.0)]
        XCTAssertEqual(anchor.restoredVisibleTop(positions: after, zoomScale: 2), 900)
    }

    func testDraftsAndTheExplicitlyUnreadMessageAreNeverMarkedRead() {
        var message = ReaderFixtures.plainMessage
        message.isSeen = false
        XCTAssertTrue(ReaderReadPolicy.shouldMarkRead(message, explicitlyUnreadId: nil))
        XCTAssertFalse(ReaderReadPolicy.shouldMarkRead(message, explicitlyUnreadId: message.id))
        message.isDraft = true
        XCTAssertFalse(ReaderReadPolicy.shouldMarkRead(message, explicitlyUnreadId: nil))
    }

    func testReadingAGroupedRowMarksItsUnreadConversationWithinItsFolders() {
        func make(_ folder: UUID, seen: Bool) -> MessageDetail {
            var m = ReaderFixtures.message(
                id: UUID(), from: "a@b.c", to: [], subject: "s", html: nil, text: "t", minutesAgo: 1, isSeen: seen)
            m = MessageDetail(
                id: m.id, accountId: m.accountId, folderId: folder, threadId: m.threadId, subject: m.subject,
                fromAddr: m.fromAddr, toAddrs: m.toAddrs, receivedAt: m.receivedAt, isSeen: seen, snippet: m.snippet,
                messageId: m.messageId, ccAddrs: nil, bccAddrs: nil, replyTo: nil, inReplyTo: nil, references: nil,
                bodyText: m.bodyText, bodyHtml: nil, sizeBytes: nil, createdAt: m.createdAt, verdict: nil)
            return m
        }
        let inbox = UUID()
        let sent = UUID()
        let opened = make(inbox, seen: false)
        let otherUnread = make(inbox, seen: false)
        let elsewhere = make(sent, seen: false)
        let alreadyRead = make(inbox, seen: true)
        let ids = ReaderReadPolicy.conversationIdsToMarkRead(
            thread: [opened, otherUnread, elsewhere, alreadyRead], openedId: opened.id, folderIds: [inbox])
        XCTAssertEqual(ids, [otherUnread.id])
    }
}
