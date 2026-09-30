import Foundation
import XCTest
@testable import MailVerdictKit

private struct Row: Identifiable, Sendable, Equatable {
    let id: UUID
    let value: Int
}

final class MVStableOrderTests: XCTestCase {

    func testAtTopAlwaysAdoptsTheFreshOrderWithNothingHeld() {
        let a = Row(id: UUID(), value: 1)
        let b = Row(id: UUID(), value: 2)
        let result = MVStableOrder.apply(shown: [a], fresh: [b, a], atTop: true)
        XCTAssertEqual(result.rows.map(\.id), [b.id, a.id])
        XCTAssertTrue(result.held.isEmpty)
    }

    func testScrolledDownKeepsShownPositionsAndRefreshesContent() {
        let id = UUID()
        let shown = [Row(id: id, value: 1)]
        let fresh = [Row(id: id, value: 2)]
        let result = MVStableOrder.apply(shown: shown, fresh: fresh, atTop: false)
        XCTAssertEqual(result.rows, [Row(id: id, value: 2)])
        XCTAssertTrue(result.held.isEmpty)
    }

    func testScrolledDownHoldsBackAnOrderNewToFresh() {
        let existing = Row(id: UUID(), value: 1)
        let brandNew = Row(id: UUID(), value: 2)
        let result = MVStableOrder.apply(shown: [existing], fresh: [brandNew, existing], atTop: false)
        XCTAssertEqual(result.rows, [existing])
        XCTAssertEqual(result.held, [brandNew])
    }

    func testScrolledDownDropsARowNoLongerInFresh() {
        let stillThere = Row(id: UUID(), value: 1)
        let deleted = Row(id: UUID(), value: 2)
        let result = MVStableOrder.apply(shown: [deleted, stillThere], fresh: [stillThere], atTop: false)
        XCTAssertEqual(result.rows, [stillThere])
        XCTAssertTrue(result.held.isEmpty)
    }

    func testTakeOverAdoptsTheFreshListWholesale() {
        let existing = Row(id: UUID(), value: 1)
        let held = Row(id: UUID(), value: 2)
        let result = MVStableOrder.takeOver(fresh: [held, existing])
        XCTAssertEqual(result.rows, [held, existing])
        XCTAssertTrue(result.held.isEmpty)
    }

    func testTakeOverWithNothingHeldLeavesRowsUnchanged() {
        let existing = Row(id: UUID(), value: 1)
        let result = MVStableOrder.takeOver(fresh: [existing])
        XCTAssertEqual(result.rows, [existing])
        XCTAssertTrue(result.held.isEmpty)
    }

    /// The regression this guards: reconstructing `held + previously shown` (the earlier
    /// implementation) always puts every held row ahead of every previously-shown one, so a row
    /// already visible before the hold that *also* moved in the server's own order during it --
    /// new mail of its own, not just a newer sibling arriving -- landed wherever it sat before the
    /// hold instead of its true, currently-correct position. Adopting `fresh` wholesale (what the
    /// web's own `takeOverFresh` does) sees it regardless of which rows are held and which were
    /// already shown.
    func testTakeOverMovesAnAlreadyShownRowBumpedDuringTheHoldToItsFreshPosition() {
        let bumped = Row(id: UUID(), value: 1)
        let other = Row(id: UUID(), value: 2)
        let brandNew = Row(id: UUID(), value: 3)
        // Before the hold: bumped and other were already shown, in that order. While held:
        // brandNew arrived, and bumped separately received new mail of its own, moving it ahead of
        // even the newly-arrived order in the server's own current order.
        let fresh = [bumped, brandNew, other]

        let result = MVStableOrder.takeOver(fresh: fresh)

        XCTAssertEqual(result.rows.map(\.id), [bumped.id, brandNew.id, other.id])
        XCTAssertTrue(result.held.isEmpty)
    }
}
