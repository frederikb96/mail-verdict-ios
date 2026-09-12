import XCTest
@testable import MailVerdictKit

final class NotificationsSupportTests: XCTestCase {

    func testIsMailAlertKind() {
        XCTAssertTrue(NotificationsSupport.isMailAlertKind("mail"))
        XCTAssertFalse(NotificationsSupport.isMailAlertKind("reminder"))
    }

    func testKnownActionLabels() {
        XCTAssertEqual(NotificationsSupport.actionLabel(for: "flag_add"), "Setting a flag")
        XCTAssertEqual(NotificationsSupport.actionLabel(for: "flag_remove"), "Clearing a flag")
        XCTAssertEqual(NotificationsSupport.actionLabel(for: "move"), "Moving a message")
        XCTAssertEqual(NotificationsSupport.actionLabel(for: "delete"), "Deleting a message")
        XCTAssertEqual(NotificationsSupport.actionLabel(for: "send"), "Sending a message")
        XCTAssertEqual(NotificationsSupport.actionLabel(for: "draft"), "Saving a draft")
    }

    func testUnknownActionFallsBackToItsRawName() {
        XCTAssertEqual(NotificationsSupport.actionLabel(for: "something_new"), "something_new")
    }
}
