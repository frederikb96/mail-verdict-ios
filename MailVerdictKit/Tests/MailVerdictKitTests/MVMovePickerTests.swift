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
}
