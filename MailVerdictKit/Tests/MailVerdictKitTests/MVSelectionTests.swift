import XCTest

@testable import MailVerdictKit

final class MVSelectionTests: XCTestCase {

    private let folderScope = MVSelectionScope(
        listScope: .folder(accountId: testAccount, folderId: testFolder), threaded: false
    )
    private let snapshot = testReceivedBase

    private func predicate(_ filter: MVSelectionFilter = .all, count: Int = 100) -> MVSelectionPredicate {
        MVSelectionPredicate(
            accountId: testAccount, folderId: testFolder, filter: filter, snapshotAt: snapshot, count: count
        )
    }

    private func selectable(_ n: Int, seen: Bool = false, mirroredAfterSnapshot: Bool = false) -> MVSelectableRow {
        MVSelectableRow(
            testRow(n, seen: seen, mirroredAt: snapshot.addingTimeInterval(mirroredAfterSnapshot ? 60 : -60))
        )
    }

    /// Unticking a row under select-all excludes it; ticking mail that arrived after the
    /// snapshot includes it explicitly. The count follows both without being tracked.
    func testUnderSelectAllTicksBecomeExclusionsAndLaterArrivalsInclusions() {
        var selection = MVSelection.all(predicate(), in: folderScope)
        let matching = selectable(1)
        let lateArrival = selectable(2, mirroredAfterSnapshot: true)

        XCTAssertTrue(selection.isSelected(matching))
        XCTAssertFalse(selection.isSelected(lateArrival))

        selection = selection.toggling(matching, in: folderScope)
        selection = selection.toggling(lateArrival, in: folderScope)

        XCTAssertFalse(selection.isSelected(matching))
        XCTAssertTrue(selection.isSelected(lateArrival))
        XCTAssertEqual(selection.count, 100)
        XCTAssertEqual(selection.excluded.keys.sorted { $0.uuidString < $1.uuidString }, [testUUID(1)])
    }

    func testAnUnreadPredicateNeverClaimsAReadRow() {
        let selection = MVSelection.all(predicate(.unread), in: folderScope)

        XCTAssertFalse(selection.isSelected(selectable(1, seen: true)))
        XCTAssertTrue(selection.isSelected(selectable(2)))
    }

    /// A selection made in one list must never act on another.
    func testASelectionFromAnotherListIsDiscardedBeforeAnyGesture() {
        let grouped = MVSelectionScope(listScope: folderScope.listScope, threaded: true)
        let selection = MVSelection.all(predicate(), in: folderScope)

        XCTAssertEqual(selection.scoped(to: grouped), .empty)
        let toggled = selection.toggling(selectable(1), in: grouped)
        XCTAssertNil(toggled.predicate)
        XCTAssertEqual(toggled.count, 1)
    }

    /// The title stays "N Selected" whatever rows are — long enough already that a nav bar
    /// truncates "N Conversations Selected" — and the conversation wording moves to the subtitle.
    func testTitleStaysShortAndTheConversationWordingMovesToTheSubtitle() {
        let explicit = MVSelection.explicit([selectable(1), selectable(2)], in: folderScope)
        let unreadAll = MVSelection.all(predicate(.unread, count: 5), in: folderScope)

        XCTAssertEqual(MVSelectionText.title(for: explicit, threaded: true), "2 Selected")
        XCTAssertEqual(MVSelectionText.title(for: unreadAll, threaded: false), "All 5 Unread")
        XCTAssertEqual(MVSelectionText.scopeNote(for: explicit, threaded: true), "2 Conversations")
        XCTAssertNil(MVSelectionText.scopeNote(for: explicit, threaded: false))
        XCTAssertNotNil(MVSelectionText.scopeNote(for: unreadAll, threaded: true))
    }
}

final class MVBulkRequestBuilderTests: XCTestCase {

    private let otherAccount = testUUID(900_010)

    func testAPredicateGoesOutAsOneScopeWithItsExclusionsAndExtraTicks() {
        let scope = MVSelectionScope(listScope: .folder(accountId: testAccount, folderId: testFolder), threaded: true)
        let predicate = MVSelectionPredicate(
            accountId: testAccount, folderId: testFolder, filter: .unread, snapshotAt: testReceivedBase, count: 10
        )
        var selection = MVSelection.all(predicate, in: scope)
        selection = selection.toggling(MVSelectableRow(testRow(3)), in: scope)
        selection = selection.toggling(
            MVSelectableRow(testRow(4, mirroredAt: testReceivedBase.addingTimeInterval(60))), in: scope
        )

        let plans = MVBulkRequestBuilder.plans(for: selection, action: .archive).plans

        XCTAssertEqual(plans.count, 1)
        XCTAssertEqual(plans.first?.accountId, testAccount)
        XCTAssertEqual(plans.first?.request.scope?.filter, "unread")
        XCTAssertEqual(plans.first?.request.scope?.excludeIds, [testUUID(3)])
        XCTAssertEqual(plans.first?.request.ids, [testUUID(4)])
        XCTAssertEqual(plans.first?.request.expandThreads, false)
    }

    /// Ticked conversation rows spanning two accounts: one request each, every one asking the
    /// server to act on the whole conversation.
    func testAnExplicitGroupedSelectionIsSentPerAccountAndExpandedToConversations() {
        let scope = MVSelectionScope(listScope: .unified(viewId: testUUID(7), name: "All"), threaded: true)
        let selection = MVSelection.explicit(
            [MVSelectableRow(testRow(1)), MVSelectableRow(testRow(2, account: otherAccount))], in: scope
        )

        let plans = MVBulkRequestBuilder.plans(for: selection, action: .trash).plans

        XCTAssertEqual(Set(plans.map(\.accountId)), [testAccount, otherAccount])
        XCTAssertTrue(plans.allSatisfy { $0.request.expandThreads && $0.request.ids?.count == 1 })
        XCTAssertEqual(plans.first { $0.accountId == otherAccount }?.request.ids, [testUUID(2)])
    }

    func testAMoveIsNeverSentToAnAccountWithoutTheDestination() {
        let scope = MVSelectionScope(listScope: .unified(viewId: testUUID(7), name: "All"), threaded: false)
        let selection = MVSelection.explicit(
            [MVSelectableRow(testRow(1)), MVSelectableRow(testRow(2, account: otherAccount))], in: scope
        )
        let destination = testUUID(4_242)

        let built = MVBulkRequestBuilder.plans(
            for: selection, action: .move, targetFolderId: { $0 == testAccount ? destination : nil }
        )

        XCTAssertEqual(built.plans.map(\.accountId), [testAccount])
        XCTAssertEqual(built.plans.first?.request.targetFolderId, destination)
        XCTAssertEqual(built.skippedAccountIds, [otherAccount])
    }

    /// A predicate has nothing to undo from, so the moves that cannot be taken back ask first;
    /// an explicit selection never does, because it gets Undo.
    func testOnlyIrreversiblePredicateActionsAskForConfirmation() {
        let scope = MVSelectionScope(listScope: .folder(accountId: testAccount, folderId: testFolder), threaded: false)
        let predicate = MVSelectionPredicate(
            accountId: testAccount, folderId: testFolder, filter: .all, snapshotAt: testReceivedBase, count: 3
        )
        let all = MVSelection.all(predicate, in: scope)
        let explicit = MVSelection.explicit([MVSelectableRow(testRow(1))], in: scope)

        XCTAssertTrue(MVBulkRequestBuilder.needsConfirmation(all, action: .trash))
        XCTAssertTrue(MVBulkRequestBuilder.needsConfirmation(all, action: .move))
        XCTAssertFalse(MVBulkRequestBuilder.needsConfirmation(all, action: .markRead))
        XCTAssertFalse(MVBulkRequestBuilder.needsConfirmation(explicit, action: .trash))
    }
}
