import XCTest
@testable import MailVerdictKit

final class OrderActionSetTests: XCTestCase {

    private let plain = OrderFlags(isFavorite: false, isOpen: true, isSealed: false)
    private let flipped = OrderFlags(isFavorite: true, isOpen: false, isSealed: true)

    func testEveryActionAppearsOnceInMenuOrder() {
        XCTAssertEqual(
            OrderActionSet.entries(for: plain).map(\.action), [.favorite, .close, .seal, .rewrite, .delete])
    }

    func testWordingFollowsTheFlags() {
        XCTAssertEqual(
            OrderActionSet.entries(for: plain).map(\.title),
            ["Favorite", "Close", "Seal", "Rewrite Summary", "Delete Order…"])
        XCTAssertEqual(
            OrderActionSet.entries(for: flipped).map(\.title),
            ["Unfavorite", "Reopen", "Unseal", "Rewrite Summary", "Delete Order…"])
    }

    func testOnlyDeleteIsDestructive() {
        XCTAssertEqual(OrderActionSet.entries(for: plain).filter(\.isDestructive).map(\.action), [.delete])
    }

    func testToggleBuildsTheRequestThatFlipsEachFlag() {
        XCTAssertEqual(OrderActionSet.toggle(.favorite, plain)?.update, OrderUpdateRequest(isFavorite: true))
        XCTAssertEqual(OrderActionSet.toggle(.close, plain)?.update, OrderUpdateRequest(isOpen: false))
        XCTAssertEqual(OrderActionSet.toggle(.seal, plain)?.update, OrderUpdateRequest(isSealed: true))
        XCTAssertEqual(OrderActionSet.toggle(.favorite, flipped)?.update, OrderUpdateRequest(isFavorite: false))
        XCTAssertEqual(OrderActionSet.toggle(.close, flipped)?.update, OrderUpdateRequest(isOpen: true))
        XCTAssertEqual(OrderActionSet.toggle(.seal, flipped)?.update, OrderUpdateRequest(isSealed: false))
    }

    func testRewriteAndDeleteAreNotFlagFlips() {
        XCTAssertNil(OrderActionSet.toggle(.rewrite, plain))
        XCTAssertNil(OrderActionSet.toggle(.delete, plain))
    }

    func testAnUnsetFlagIsNotSentOnTheWire() throws {
        let data = try JSONEncoder().encode(OrderUpdateRequest(isOpen: false))
        XCTAssertEqual(String(decoding: data, as: UTF8.self), #"{"is_open":false}"#)
    }
}
