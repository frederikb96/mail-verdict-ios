import XCTest
@testable import MailVerdictKit

final class ContactPhotoSourceTests: XCTestCase {

    func testASameOriginPathResolvesToEmbedded() {
        let contactId = UUID()
        let entry = ContactPhotoIndexEntry(contactId: contactId, photoUrl: "/api/contacts/\(contactId)/photo")
        XCTAssertEqual(entry.avatarSource, .embedded(contactId: contactId))
    }

    func testAThirdPartyAddressResolvesToRemote() {
        let entry = ContactPhotoIndexEntry(
            contactId: UUID(), photoUrl: "https://example.com/photo.jpg")
        XCTAssertEqual(entry.avatarSource, .remote(URL(string: "https://example.com/photo.jpg")!))
    }

    func testAMalformedURLResolvesToNil() {
        let entry = ContactPhotoIndexEntry(contactId: UUID(), photoUrl: "not a url")
        XCTAssertNil(entry.avatarSource)
    }
}
