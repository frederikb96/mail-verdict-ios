import XCTest
@testable import MailVerdictKit

final class MVArrayMoveTests: XCTestCase {

    func testMovingAnEarlierElementLater() async throws {
        var items = ["A", "B", "C", "D"]
        items.move(fromOffsets: [0], toOffset: 3)
        XCTAssertEqual(items, ["B", "C", "A", "D"])
    }

    func testMovingALaterElementEarlier() async throws {
        var items = ["A", "B", "C", "D"]
        items.move(fromOffsets: [3], toOffset: 0)
        XCTAssertEqual(items, ["D", "A", "B", "C"])
    }

    func testMovingSeveralElementsAtOncePreservesTheirRelativeOrder() async throws {
        var items = ["A", "B", "C", "D", "E"]
        items.move(fromOffsets: [0, 2], toOffset: 5)
        XCTAssertEqual(items, ["B", "D", "E", "A", "C"])
    }
}

final class MVAccountOrderStoreTests: XCTestCase {

    func testAppliesTheStoredOrderFirstThenAnyUnlistedAccountAfter() async throws {
        let a = TestAccounts.make(name: "A")
        let b = TestAccounts.make(name: "B")
        let c = TestAccounts.make(name: "C")
        // `c` predates the stored order (a newly added account) and must still appear, last.
        let ordered = MVAccountOrderStore.applying(order: [b.id, a.id], to: [a, b, c])
        XCTAssertEqual(ordered.map(\.name), ["B", "A", "C"])
    }

    func testAnOrderNamingAnAccountThatNoLongerExistsIsSkippedRatherThanCrashing() async throws {
        let a = TestAccounts.make(name: "A")
        let ordered = MVAccountOrderStore.applying(order: [UUID(), a.id], to: [a])
        XCTAssertEqual(ordered.map(\.name), ["A"])
    }
}

final class MVAccountConnectionStateTests: XCTestCase {

    func testANonErrorStateIsAlwaysOk() async throws {
        XCTAssertEqual(MVAccountConnectionState.classify(state: "active", lastFullSync: false), .ok)
        XCTAssertEqual(MVAccountConnectionState.classify(state: "syncing", lastFullSync: true), .ok)
    }

    func testAnErroredAccountThatHasSyncedBeforeIsRetryingNotDead() async throws {
        XCTAssertEqual(MVAccountConnectionState.classify(state: "error", lastFullSync: true), .retrying)
    }

    func testAnErroredAccountThatHasNeverCompletedASyncHasNeverConnected() async throws {
        XCTAssertEqual(MVAccountConnectionState.classify(state: "error", lastFullSync: false), .neverConnected)
    }
}

/// A minimal, valid `AccountResponse` for tests that only care about identity and display name —
/// every other field is spam-detection/retention plumbing none of these tests touch.
enum TestAccounts {
    static func make(name: String) -> AccountResponse {
        AccountResponse(
            id: UUID(), name: name, imapHost: "imap.example.com", imapPort: 993,
            imapUser: "user@example.com", smtpHost: nil, smtpPort: nil, smtpUser: nil,
            stateError: nil, capabilities: nil, createdAt: Date(), updatedAt: Date(), emoji: nil,
            folderOrder: nil, trashRetentionDays: nil, junkRetentionDays: nil
        )
    }
}
