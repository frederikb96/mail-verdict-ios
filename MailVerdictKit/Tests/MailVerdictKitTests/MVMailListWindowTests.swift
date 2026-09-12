import XCTest

@testable import MailVerdictKit

final class MVMailListWindowTests: XCTestCase {

    private func ids(_ rows: [MessageSummary]) -> [UUID] { rows.map(\.id) }

    /// New mail at the top comes in; the window is never grown below its old last row, which
    /// would move the list's end underneath the reader.
    func testARefreshAddsArrivalsButNeverGrowsTheWindowBelowItsLastRow() {
        let merged = MVMailListWindow.mergeRefreshed(
            current: testRows(3...10), fresh: testRows(1...12), freshHasMore: true, currentHasMore: true
        )

        XCTAssertEqual(ids(merged.rows), ids(testRows(1...10)))
        XCTAssertTrue(merged.hasMore)
    }

    /// A window deeper than one refresh reads keeps its unread-over tail as it was.
    func testRowsBeyondWhatTheRefreshReachedAreKept() {
        let merged = MVMailListWindow.mergeRefreshed(
            current: testRows(1...20), fresh: testRows(0...8), freshHasMore: true, currentHasMore: false
        )

        XCTAssertEqual(ids(merged.rows), ids(testRows(0...20)))
        XCTAssertFalse(merged.hasMore)
    }

    /// In an unread-only window the server stops returning a row once it is read; the reader
    /// still sees it until they leave or cycle the filter.
    func testARowReadInAnUnreadWindowStaysListedWhenPreserved() {
        let current = testRows(1...4)
        let fresh = [testRow(1), testRow(3), testRow(4), testRow(5)]

        let preserved = MVMailListWindow.mergeRefreshed(
            current: current, fresh: fresh, freshHasMore: false, currentHasMore: false,
            preserveIds: [testUUID(2)]
        )
        let dropped = MVMailListWindow.mergeRefreshed(
            current: current, fresh: fresh, freshHasMore: false, currentHasMore: false
        )

        XCTAssertEqual(ids(preserved.rows), ids(testRows(1...4)))
        XCTAssertEqual(ids(dropped.rows), [testUUID(1), testUUID(3), testUUID(4)])
    }

    /// A window opened around a message never gains rows above its first one from a refresh —
    /// that would put two disjoint runs of mail in one list — and still knows newer mail exists.
    func testAWindowAwayFromTheNewestEdgeDropsArrivalsAboveItAndKeepsItsLastRow() {
        var fresh = testRows(17...29)
        fresh.removeAll { $0.id == testUUID(25) }

        let merged = MVMailListWindow.mergeRefreshedFromBelow(
            current: testRows(20...30), freshAboveLast: fresh, freshHasMoreNewer: true
        )

        XCTAssertEqual(ids(merged.rows), ids(testRows(20...30).filter { $0.id != testUUID(25) }))
        XCTAssertTrue(merged.hasNewer)
    }

    func testAWindowWhoseRefreshFindsNothingAboveItBecomesTheNewestWindow() {
        let merged = MVMailListWindow.mergeRefreshedFromBelow(
            current: testRows(20...30), freshAboveLast: testRows(20...29), freshHasMoreNewer: false
        )

        XCTAssertEqual(ids(merged.rows), ids(testRows(20...30)))
        XCTAssertFalse(merged.hasNewer)
    }

    /// A page fetched against a cursor a refresh has since moved must not duplicate or reorder.
    func testAnOlderPageOnlyAppendsRowsBelowTheLastRow() {
        let appended = MVMailListWindow.appendingOlder(
            [testRow(0), testRow(4), testRow(5), testRow(6)], to: testRows(1...5))

        XCTAssertEqual(ids(appended), ids(testRows(1...6)))
    }
}
