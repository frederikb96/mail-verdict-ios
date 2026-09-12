import Foundation
import MailVerdictKit
import XCTest

/// The server reads which keys a PATCH body carries: an omitted key is left alone, an explicit
/// `null` clears it. Sending the folder scope back to the arrival-folder default depends on that
/// `null` surviving encoding, and nothing else would notice it silently turning into "no change".
final class PushSubscriptionUpdateTests: XCTestCase {

    private func encoded(_ update: PushSubscriptionUpdate) throws -> [String: Any] {
        let data = try JSONEncoder().encode(update)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    func testTheDefaultFolderScopeIsSentAsAnExplicitNull() throws {
        let body = try encoded(PushSubscriptionUpdate(alertFolderIds: .some(nil)))
        XCTAssertEqual(Array(body.keys), ["alert_folder_ids"])
        XCTAssertTrue(body["alert_folder_ids"] is NSNull)
    }

    func testAnUntouchedFieldIsLeftOutOfTheBody() throws {
        let body = try encoded(PushSubscriptionUpdate(mutedChannels: ["mail"]))
        XCTAssertEqual(Array(body.keys), ["muted_channels"])
    }
}
