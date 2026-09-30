import XCTest
@testable import MailVerdictKit

final class MessageActionSetTests: XCTestCase {

    private func context(
        surface: MVMessageActionSurface, source: MVMessageActionSource = .list, isRead: Bool = false,
        isStarred: Bool = false, isInTrash: Bool = false, isInJunk: Bool = false,
        isInGlacier: Bool = false,
        verdict: MVMessageVerdictContext? = nil, hasBlockedImages: Bool = false, canvasIsDark: Bool = false
    ) -> MVMessageContext {
        MVMessageContext(
            surface: surface, source: source, isRead: isRead, isStarred: isStarred,
            isInTrash: isInTrash, isInJunk: isInJunk, isInGlacier: isInGlacier, verdict: verdict,
            hasBlockedImages: hasBlockedImages, canvasIsDark: canvasIsDark
        )
    }

    private func actions(_ groups: [MVMessageActionGroup], in kind: MVMessageActionGroup.Kind) -> [MVMessageUIAction]? {
        groups.first { $0.kind == kind }?.actions
    }

    func testRespondGroupIsAlwaysFirstAndAlwaysPresent() {
        let groups = MessageActionSet.actions(for: context(surface: .swipeSheet))
        XCTAssertEqual(groups.first?.kind, .respond)
        XCTAssertEqual(actions(groups, in: .respond), [.reply, .replyAll, .forward])
    }

    func testVerdictGroupIsAbsentWithNoVerdict() {
        let groups = MessageActionSet.actions(for: context(surface: .swipeSheet, verdict: nil))
        XCTAssertNil(actions(groups, in: .verdict))
    }

    func testVerdictGroupAppearsWhenAVerdictExists() {
        let groups = MessageActionSet.actions(
            for: context(surface: .swipeSheet, verdict: MVMessageVerdictContext(isSpam: true, modelUsed: "gpt"))
        )
        XCTAssertEqual(actions(groups, in: .verdict), [.confirmVerdict, .correctVerdict])
    }

    func testStateGroupTogglesReadStarAndJunk() {
        let unread = MessageActionSet.actions(for: context(surface: .swipeSheet, isRead: false, isStarred: false))
        XCTAssertEqual(
            actions(unread, in: .state), [.markRead, .star, .moveTo, .moveToJunk, .archive]
        )

        let readStarredJunk = MessageActionSet.actions(
            for: context(surface: .swipeSheet, isRead: true, isStarred: true, isInJunk: true)
        )
        XCTAssertEqual(
            actions(readStarredJunk, in: .state), [.markUnread, .unstar, .moveTo, .notJunk, .archive]
        )
    }

    /// Spam/not-spam rulings against a glaciered message are not supported server-side yet --
    /// everything else in the state group stays. Checked on every surface the Options set is
    /// shown on: the swipe sheet, the context menu and the reader's own Options menu.
    func testJunkToggleIsAbsentOnAGlacieredMessageOnEverySurface() {
        let swipeSheet = MessageActionSet.actions(for: context(surface: .swipeSheet, isInGlacier: true))
        XCTAssertEqual(actions(swipeSheet, in: .state), [.markRead, .star, .moveTo, .archive])

        let contextMenu = MessageActionSet.actions(for: context(surface: .contextMenu, isInGlacier: true))
        XCTAssertEqual(actions(contextMenu, in: .state), [.markRead, .star, .moveTo, .archive])

        // The reader's Options menu never repeats Archive (it lives in the bottom bar there), so
        // the glaciered state group is one item shorter than the other two surfaces'.
        let readerOptions = MessageActionSet.actions(for: context(surface: .readerOptionsMenu, isInGlacier: true))
        XCTAssertEqual(actions(readerOptions, in: .state), [.markRead, .star, .moveTo])
    }

    /// Reply, reply-all and forward need only the outbox, never the original message on the mail
    /// server -- so they stay offered for a glaciered message exactly as for a live one, on every
    /// surface.
    func testRespondGroupIsUnchangedOnAGlacieredMessageOnEverySurface() {
        for surface in [MVMessageActionSurface.swipeSheet, .contextMenu, .readerOptionsMenu] {
            let groups = MessageActionSet.actions(for: context(surface: surface, isInGlacier: true))
            XCTAssertEqual(actions(groups, in: .respond), [.reply, .replyAll, .forward], "\(surface)")
        }
    }

    /// Archive lives in the swipe sheet and context menu only — the reader has it in its own
    /// bottom bar and never repeats it in the Options menu.
    func testArchiveIsAbsentFromTheReaderOptionsMenu() {
        let groups = MessageActionSet.actions(for: context(surface: .readerOptionsMenu))
        XCTAssertFalse(actions(groups, in: .state)?.contains(.archive) ?? true)
    }

    func testToolsGroupOnlyAppearsInTheReaderOptionsMenu() {
        XCTAssertNil(actions(MessageActionSet.actions(for: context(surface: .swipeSheet)), in: .tools))
        XCTAssertNil(actions(MessageActionSet.actions(for: context(surface: .contextMenu)), in: .tools))
        XCTAssertNotNil(actions(MessageActionSet.actions(for: context(surface: .readerOptionsMenu)), in: .tools))
    }

    func testRemoteImageActionsOnlyAppearWhenImagesAreBlocked() {
        let blocked = MessageActionSet.actions(for: context(surface: .readerOptionsMenu, hasBlockedImages: true))
        let tools = actions(blocked, in: .tools) ?? []
        XCTAssertTrue(tools.contains(.loadImagesOnce))
        XCTAssertTrue(tools.contains(.alwaysLoadFromSender))
        XCTAssertTrue(tools.contains(.alwaysLoadFromDomain))

        let notBlocked = MessageActionSet.actions(for: context(surface: .readerOptionsMenu, hasBlockedImages: false))
        let toolsNotBlocked = actions(notBlocked, in: .tools) ?? []
        XCTAssertFalse(toolsNotBlocked.contains(.loadImagesOnce))
    }

    func testCanvasToggleOffersTheOppositeOfTheCurrentCanvas() {
        let dark = actions(
            MessageActionSet.actions(for: context(surface: .readerOptionsMenu, canvasIsDark: true)), in: .tools)
        XCTAssertTrue(dark?.contains(.lightBackground) ?? false)

        let light = actions(
            MessageActionSet.actions(for: context(surface: .readerOptionsMenu, canvasIsDark: false)), in: .tools)
        XCTAssertTrue(light?.contains(.darkBackground) ?? false)
    }

    func testShowInFolderOnlyAppearsForSearchSpamReviewAndOrderSources() {
        for source in [MVMessageActionSource.search, .spamReview, .order] {
            let tools = actions(
                MessageActionSet.actions(for: context(surface: .readerOptionsMenu, source: source)), in: .tools)
            XCTAssertTrue(tools?.contains(.showInFolder) ?? false, "\(source)")
        }
        for source in [MVMessageActionSource.list, .reader] {
            let tools = actions(
                MessageActionSet.actions(for: context(surface: .readerOptionsMenu, source: source)), in: .tools)
            XCTAssertFalse(tools?.contains(.showInFolder) ?? true, "\(source)")
        }
    }

    func testDestructiveGroupIsDeleteOrDeleteForeverInTrashForSwipeAndContextMenu() {
        for surface in [MVMessageActionSurface.swipeSheet, .contextMenu] {
            XCTAssertEqual(
                actions(MessageActionSet.actions(for: context(surface: surface, isInTrash: false)), in: .destructive),
                [.delete]
            )
            XCTAssertEqual(
                actions(MessageActionSet.actions(for: context(surface: surface, isInTrash: true)), in: .destructive),
                [.deleteForever]
            )
        }
    }

    /// A glaciered message is the only copy that exists, the same reason Trash turns Delete into
    /// Delete Forever — checked on every surface the destructive group appears on.
    func testDestructiveGroupIsDeleteForeverOnAGlacieredMessageForSwipeAndContextMenu() {
        for surface in [MVMessageActionSurface.swipeSheet, .contextMenu] {
            XCTAssertEqual(
                actions(MessageActionSet.actions(for: context(surface: surface, isInGlacier: true)), in: .destructive),
                [.deleteForever], "\(surface)"
            )
        }
    }

    /// The reader's Options menu never duplicates its own bottom-bar Delete — except for Delete
    /// Forever while in Trash or the glacier.
    func testReaderOptionsMenuHasNoDestructiveGroupExceptDeleteForeverInTrashOrTheGlacier() {
        XCTAssertNil(
            actions(
                MessageActionSet.actions(for: context(surface: .readerOptionsMenu, isInTrash: false)), in: .destructive)
        )
        XCTAssertEqual(
            actions(
                MessageActionSet.actions(for: context(surface: .readerOptionsMenu, isInTrash: true)), in: .destructive),
            [.deleteForever]
        )
        XCTAssertEqual(
            actions(
                MessageActionSet.actions(for: context(surface: .readerOptionsMenu, isInGlacier: true)), in: .destructive
            ),
            [.deleteForever]
        )
    }
}

final class MailActionServiceTests: XCTestCase {

    func testBulkActionMappingForEveryToggleAction() {
        XCTAssertEqual(MailActionService.bulkAction(for: .markRead), .markRead)
        XCTAssertEqual(MailActionService.bulkAction(for: .markUnread), .markUnread)
        XCTAssertEqual(MailActionService.bulkAction(for: .star), .flag)
        XCTAssertEqual(MailActionService.bulkAction(for: .unstar), .unflag)
        XCTAssertEqual(MailActionService.bulkAction(for: .archive), .archive)
        XCTAssertEqual(MailActionService.bulkAction(for: .moveToJunk), .spam)
        XCTAssertEqual(MailActionService.bulkAction(for: .notJunk), .notSpam)
        XCTAssertEqual(MailActionService.bulkAction(for: .delete), .trash)
        XCTAssertEqual(MailActionService.bulkAction(for: .deleteForever), .expunge)
    }

    func testMoveToNeedsATargetFolderResolvedFirst() {
        XCTAssertNil(MailActionService.bulkAction(for: .moveTo))
        XCTAssertEqual(MailActionService.bulkAction(for: .moveTo, targetFolderId: UUID()), .move)
    }

    func testNonActionableUIItemsMapToNothing() {
        XCTAssertNil(MailActionService.bulkAction(for: .reply))
        XCTAssertNil(MailActionService.bulkAction(for: .findInMessage))
    }

    func testAutoAdvancePrefersTheLastNavigatedDirection() {
        let older = UUID(), newer = UUID()
        XCTAssertEqual(
            MailActionService.autoAdvanceTarget(neighbours: (older: older, newer: newer), lastDirection: .older),
            older
        )
        XCTAssertEqual(
            MailActionService.autoAdvanceTarget(neighbours: (older: older, newer: newer), lastDirection: .newer),
            newer
        )
    }

    func testAutoAdvanceFallsBackToTheOtherSideWhenThePreferredOneIsGone() {
        let newer = UUID()
        XCTAssertEqual(
            MailActionService.autoAdvanceTarget(neighbours: (older: nil, newer: newer), lastDirection: .older),
            newer
        )
    }

    func testAutoAdvanceReturnsNilAtTheEndOfTheLoadedWindow() {
        XCTAssertNil(MailActionService.autoAdvanceTarget(neighbours: (older: nil, newer: nil), lastDirection: .older))
    }

    func testExplicitUnreadTrackerHoldsExactlyOneIdAtATime() async {
        let tracker = MVExplicitUnreadTracker()
        let a = UUID(), b = UUID()
        await tracker.markExplicit(a)
        var isExplicit = await tracker.isExplicit(a)
        XCTAssertTrue(isExplicit)

        await tracker.markExplicit(b)
        isExplicit = await tracker.isExplicit(a)
        XCTAssertFalse(isExplicit)
        isExplicit = await tracker.isExplicit(b)
        XCTAssertTrue(isExplicit)

        await tracker.clear()
        isExplicit = await tracker.isExplicit(b)
        XCTAssertFalse(isExplicit)
    }
}
