import XCTest

@testable import MailVerdictKit

final class MVListAnchoringTests: XCTestCase {

    /// A 40 pt banner above the rows, bars top and bottom — every term of the arithmetic is
    /// non-zero, so a formula that drops one cannot pass by accident.
    private let geometry = MVListGeometry(
        rowHeight: 100, firstRowY: 40, trailingHeight: 44, topInset: 60, bottomInset: 80, viewportHeight: 800
    )

    private func ids(_ range: ClosedRange<Int>) -> [UUID] { range.map(testUUID) }

    /// Mail arriving above a reader mid-list must not move the row they are reading, down to
    /// the point within it.
    func testRowsPrependedAboveTheReaderLeaveTheirRowAtTheSamePoint() {
        let old = ids(10...60)
        let new = ids(7...60)
        let offset = 2_537.5
        let before = MVListAnchoring.anchor(offsetY: offset, geometry: geometry, rowIds: old)

        let corrected = MVListAnchoring.offsetAfterChange(
            offsetY: offset, oldIds: old, newIds: new, geometry: geometry, windowAtNewestEdge: true
        )

        XCTAssertEqual(corrected, 2_837.5)
        XCTAssertEqual(before?.rowId, testUUID(35))
        XCTAssertEqual(MVListAnchoring.anchor(offsetY: corrected, geometry: geometry, rowIds: new), before)
    }

    func testARowLeavingAboveTheReaderShiftsByExactlyOneRow() {
        let old = ids(1...50)
        var new = old
        new.remove(at: 3)

        let corrected = MVListAnchoring.offsetAfterChange(
            offsetY: 1_000, oldIds: old, newIds: new, geometry: geometry, windowAtNewestEdge: true
        )

        XCTAssertEqual(corrected, 900)
    }

    /// The reader's own row leaving (archived elsewhere) must not throw them to the top: the
    /// nearest surviving row stands in for it.
    func testTheAnchorRowLeavingFallsBackToItsNearestSurvivor() {
        let old = ids(1...50)
        let new = old.filter { $0 != testUUID(11) && $0 != testUUID(3) }

        let corrected = MVListAnchoring.offsetAfterChange(
            offsetY: 1_000, oldIds: old, newIds: new, geometry: geometry, windowAtNewestEdge: true
        )

        XCTAssertEqual(corrected, 900)
    }

    /// Exactly the top of a newest-edge window shows new mail; one point below it, or any window
    /// opened away from the newest edge, compensates instead.
    func testOnlyAReaderRestingAtTheTopOfTheNewestWindowSeesArrivalsPushTheList() {
        let old = ids(4...50)
        let new = ids(1...50)

        XCTAssertEqual(
            MVListAnchoring.offsetAfterChange(
                offsetY: -60, oldIds: old, newIds: new, geometry: geometry, windowAtNewestEdge: true
            ), -60)
        XCTAssertEqual(
            MVListAnchoring.offsetAfterChange(
                offsetY: -59, oldIds: old, newIds: new, geometry: geometry, windowAtNewestEdge: true
            ), 241)
        XCTAssertEqual(
            MVListAnchoring.offsetAfterChange(
                offsetY: -60, oldIds: old, newIds: new, geometry: geometry, windowAtNewestEdge: false
            ), 240)
    }

    func testNewRowsAboveCountsOnlyArrivalsAboveTheReader() {
        let old = ids(10...60)
        let new = [testUUID(1), testUUID(2)] + ids(10...40) + [testUUID(3)] + ids(41...60)

        XCTAssertEqual(
            MVListAnchoring.newRowsAbove(offsetY: 2_537.5, oldIds: old, newIds: new, geometry: geometry), 2
        )
    }

    /// A banner in view puts the anchor above its row; restoring must land on the same offset.
    func testRestoringAnAnchorTakenWithTheBannerInViewLandsOnTheSameOffset() {
        let rows = ids(1...50)
        let anchor = MVListAnchoring.anchor(offsetY: -60, geometry: geometry, rowIds: rows)

        XCTAssertEqual(anchor?.offsetInRow, -40)
        XCTAssertEqual(anchor.flatMap { MVListAnchoring.offsetY(restoring: $0, rowIds: rows, geometry: geometry) }, -60)
    }

    func testRevealLeavesAVisibleRowAloneAndOtherwiseMovesTheLeast() {
        XCTAssertNil(MVListAnchoring.offsetRevealing(rowIndex: 12, offsetY: 1_000, geometry: geometry, rowCount: 50))
        XCTAssertEqual(
            MVListAnchoring.offsetRevealing(rowIndex: 10, offsetY: 1_000, geometry: geometry, rowCount: 50), 980)
        XCTAssertEqual(
            MVListAnchoring.offsetRevealing(rowIndex: 20, offsetY: 1_000, geometry: geometry, rowCount: 50), 1_420)
    }

    func testUpperThirdPlacementIsClampedAtTheEndOfTheRows() {
        XCTAssertEqual(MVListAnchoring.offsetPlacingInUpperThird(rowIndex: 20, geometry: geometry, rowCount: 50), 1_760)
        XCTAssertEqual(MVListAnchoring.offsetPlacingInUpperThird(rowIndex: 49, geometry: geometry, rowCount: 50), 4_364)
    }

    func testPagesAreRequestedWithinTwoScreensOfEitherEnd() {
        let nearBottom = MVListAnchoring.pagingNeeds(offsetY: 4_000, geometry: geometry, rowCount: 50)
        XCTAssertTrue(nearBottom.older)
        XCTAssertFalse(nearBottom.newer)

        let nearTop = MVListAnchoring.pagingNeeds(offsetY: 1_000, geometry: geometry, rowCount: 50)
        XCTAssertFalse(nearTop.older)
        XCTAssertTrue(nearTop.newer)
    }
}
