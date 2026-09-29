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

    func testTakeOverPrependsHeldRowsAheadOfWhatWasAlreadyShown() {
        let existing = Row(id: UUID(), value: 1)
        let held = Row(id: UUID(), value: 2)
        let result = MVStableOrder.takeOver(rows: [existing], held: [held])
        XCTAssertEqual(result.rows, [held, existing])
        XCTAssertTrue(result.held.isEmpty)
    }

    func testTakeOverWithNothingHeldLeavesRowsUnchanged() {
        let existing = Row(id: UUID(), value: 1)
        let result = MVStableOrder.takeOver(rows: [existing], held: [])
        XCTAssertEqual(result.rows, [existing])
    }
}
