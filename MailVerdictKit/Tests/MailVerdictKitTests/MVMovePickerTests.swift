import XCTest

@testable import MailVerdictKit

final class MVMovePickerTests: XCTestCase {

    private func folder(_ n: Int, _ name: String, specialUse: String? = nil) -> MVMoveTarget {
        MVMoveTarget(
            folder: FolderOrderItem(folderId: testUUID(n), imapName: name, displayName: nil, specialUse: specialUse),
            accountId: testAccount
        )
    }

    /// Recents lead, in recency order; the message's own folder is never offered even when it is
    /// a recent one; typing searches every folder by name, recency aside.
    func testRecentsLeadButNeverOfferTheCurrentFolderAndTypingSearchesByName() {
        let targets = [
            folder(1, "INBOX", specialUse: "inbox"), folder(2, "Projects"), folder(3, "Receipts"),
            folder(4, "Archive", specialUse: "archive"),
        ]
        let recents = [testUUID(3).uuidString, testUUID(1).uuidString]

        let idle = MVMovePicker.ordered(targets, excludingFolderId: testUUID(1), recentIds: recents, query: "")
        let typed = MVMovePicker.ordered(targets, excludingFolderId: testUUID(1), recentIds: recents, query: "  pro ")

        XCTAssertEqual(idle.map(\.name), ["Receipts", "Projects", "Archive"])
        XCTAssertEqual(typed.map(\.name), ["Projects"])
    }

    func testAUnifiedTargetResolvesToEachAccountsOwnFolder() {
        let other = testUUID(900_010)
        let view = UnifiedFolderResponse(
            id: testUUID(50), unifiedName: "Receipts", emoji: nil,
            folders: [
                UnifiedFolderSource(
                    accountId: testAccount, accountName: "A", accountEmoji: nil, folderId: testUUID(61),
                    imapName: "Receipts", specialUse: nil),
                UnifiedFolderSource(
                    accountId: other, accountName: "B", accountEmoji: nil, folderId: testUUID(62),
                    imapName: "Belege", specialUse: nil),
            ], unreadCount: 0, totalCount: 0
        )
        let target = MVMoveTarget(unifiedView: view)

        XCTAssertEqual(target.folderId(forAccount: testAccount), testUUID(61))
        XCTAssertEqual(target.folderId(forAccount: other), testUUID(62))
        XCTAssertNil(target.folderId(forAccount: testUUID(63)))
    }

    func testRecentTargetsAreDeduplicatedAndCapped() {
        let defaults = UserDefaults(suiteName: "move-picker-tests-\(UUID().uuidString)")!
        let recents = MVRecentMoveTargets(defaults: defaults)

        for n in 1...7 { recents.record(targetId: "t\(n)", accountKey: "a") }
        recents.record(targetId: "t4", accountKey: "a")

        XCTAssertEqual(recents.recentIds(accountKey: "a"), ["t4", "t7", "t6", "t5", "t3"])
        XCTAssertEqual(recents.recentIds(accountKey: "b"), [])
    }

    func testASpecialUseFolderWithoutADisplayNameReadsByRole() {
        XCTAssertEqual(folderDisplayName(imapName: "INBOX", displayName: nil, specialUse: "inbox"), "Inbox")
        XCTAssertEqual(
            folderDisplayName(imapName: "Gelöschte Elemente", displayName: nil, specialUse: "trash"), "Trash")
        XCTAssertEqual(folderDisplayName(imapName: "Receipts", displayName: nil, specialUse: nil), "Receipts")
        XCTAssertEqual(folderDisplayName(imapName: "INBOX", displayName: "Main", specialUse: "inbox"), "Main")
    }

    /// The glacier target carries its own icon and its own flag, checked before every move to it
    /// — the one Move-picker target that is not on the mail server at all.
    func testTheGlacierTargetIsFlaggedAndCarriesItsOwnIcon() {
        let glacier = MVMoveTarget(
            folder: FolderOrderItem(
                folderId: testUUID(9), imapName: "Glacier", displayName: nil, specialUse: nil, kind: "glacier"),
            accountId: testAccount
        )
        XCTAssertTrue(glacier.isGlacier)
        XCTAssertEqual(glacier.symbol, "snowflake")

        let ordinary = folder(1, "INBOX", specialUse: "inbox")
        XCTAssertFalse(ordinary.isGlacier)
    }

    /// A unified-view target is never flagged as the glacier, even when every account it spans
    /// happens to have one enabled — it stands for several accounts' folders at once, not for one
    /// account's glacier specifically.
    func testAUnifiedTargetIsNeverFlaggedAsTheGlacier() {
        let view = UnifiedFolderResponse(
            id: testUUID(51), unifiedName: "Everything", emoji: nil, folders: [], unreadCount: 0, totalCount: 0)
        XCTAssertFalse(MVMoveTarget(unifiedView: view).isGlacier)
    }
}

final class GlacierMoveWarningTests: XCTestCase {

    func testTitleAndMessageNameTheCount() {
        XCTAssertEqual(GlacierMoveWarning.title(count: 1), "Move to Glacier?")
        XCTAssertEqual(GlacierMoveWarning.title(count: 3), "Move 3 Messages to Glacier?")

        XCTAssertTrue(GlacierMoveWarning.message(count: 1).hasPrefix("This message"))
        XCTAssertTrue(GlacierMoveWarning.message(count: 3).hasPrefix("These 3 messages"))
        XCTAssertTrue(GlacierMoveWarning.message(count: 1).contains("leave the mail server for good"))
    }
}

final class GlacierDeleteWarningTests: XCTestCase {

    func testMessageNamesTheOnlyCopyAndThatItIsPermanent() {
        XCTAssertTrue(GlacierDeleteWarning.message(count: 1).contains("only copy"))
        XCTAssertTrue(GlacierDeleteWarning.message(count: 1).contains("permanent"))
    }

    /// Emptying the glacier is the one bulk surface that can act on more than one message at
    /// once — the wording still has to say "only copies", plural, and name the count.
    func testBulkMessageNamesTheCount() {
        let message = GlacierDeleteWarning.message(count: 5)
        XCTAssertTrue(message.contains("only copies"))
        XCTAssertTrue(message.contains("5"))
        XCTAssertTrue(message.contains("permanent"))
    }
}

final class GlacierRestoreWarningTests: XCTestCase {

    func testTitleNamesTheActionAndTheCount() {
        XCTAssertEqual(GlacierRestoreWarning.title(action: .archive, count: 1), "Archive?")
        XCTAssertEqual(GlacierRestoreWarning.title(action: .archive, count: 3), "Archive 3 Messages?")
        XCTAssertEqual(GlacierRestoreWarning.title(action: .trash, count: 1), "Move to Trash?")
        XCTAssertEqual(GlacierRestoreWarning.title(action: .trash, count: 2), "Move 2 Messages to Trash?")
        XCTAssertEqual(GlacierRestoreWarning.title(action: .move, count: 1), "Move to This Folder?")
        XCTAssertEqual(GlacierRestoreWarning.title(action: .move, count: 4), "Move 4 Messages?")
    }

    func testConfirmLabelMatchesEachAction() {
        XCTAssertEqual(GlacierRestoreWarning.confirmLabel(.archive), "Archive")
        XCTAssertEqual(GlacierRestoreWarning.confirmLabel(.trash), "Move to Trash")
        XCTAssertEqual(GlacierRestoreWarning.confirmLabel(.move), "Move")
    }

    /// The reverse of `GlacierMoveWarning`'s wording: this one says the message goes back onto
    /// the server, singular and plural, and never mentions "leave" -- the two are never
    /// confusable by a glance at the dialog alone.
    func testMessageNamesTheCountAndTheDirection() {
        XCTAssertTrue(GlacierRestoreWarning.message(count: 1).hasPrefix("This message"))
        XCTAssertTrue(GlacierRestoreWarning.message(count: 1).contains("goes back onto the mail server"))
        XCTAssertTrue(GlacierRestoreWarning.message(count: 3).hasPrefix("These 3 messages"))
        XCTAssertTrue(GlacierRestoreWarning.message(count: 3).contains("go back onto the mail server"))
        XCTAssertFalse(GlacierRestoreWarning.message(count: 1).contains("leave"))
    }
}
