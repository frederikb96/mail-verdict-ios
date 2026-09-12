import XCTest

@testable import MailVerdictKit

/// Where the composer starts focus — a pure function of the intent, so the branch a future
/// `ComposeIntent.Kind` case forgets to cover is caught here rather than by squinting at a
/// screenshot.
final class ComposeIntentFocusTests: XCTestCase {

    func testANewMessageFocusesRecipients() {
        XCTAssertTrue(ComposeIntent(kind: .new(accountId: nil)).focusesRecipientsOnOpen)
    }

    func testReplyReplyAllAndForwardFocusTheBody() {
        let messageId = UUID()
        XCTAssertFalse(ComposeIntent(kind: .reply(messageId: messageId)).focusesRecipientsOnOpen)
        XCTAssertFalse(ComposeIntent(kind: .replyAll(messageId: messageId)).focusesRecipientsOnOpen)
        XCTAssertFalse(ComposeIntent(kind: .forward(messageId: messageId)).focusesRecipientsOnOpen)
    }

    func testAReopenedDraftAndARestoredSendFocusTheBody() {
        XCTAssertFalse(ComposeIntent(kind: .draft(messageId: UUID())).focusesRecipientsOnOpen)
        XCTAssertFalse(ComposeIntent(kind: .undoRestore(pendingSendId: UUID())).focusesRecipientsOnOpen)
    }

    func testAMailtoLinkWithNoRecipientFocusesRecipients() {
        let link = MailtoLink(to: [], subject: "Hi")
        XCTAssertTrue(ComposeIntent(kind: .mailto(link)).focusesRecipientsOnOpen)
    }

    func testAMailtoLinkThatAlreadyNamesARecipientFocusesTheBody() {
        let link = MailtoLink(to: ["a@example.com"])
        XCTAssertFalse(ComposeIntent(kind: .mailto(link)).focusesRecipientsOnOpen)
    }
}
