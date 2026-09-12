import Foundation
import XCTest

@testable import MailVerdictKit

/// The screenshot run answers every composer request from these routes; one that does not decode
/// would leave the capture on an error state rather than the composer.
final class ComposeFixturesTests: XCTestCase {

    override func tearDown() {
        MVFixtureURLProtocol.resetToDefaults()
        super.tearDown()
    }

    func testEveryRegisteredRouteDecodesAsTheClientReadsIt() throws {
        ComposeFixtures.register()
        let decoder = JSONDecoder.mvDefault
        func body(_ path: String) -> Data {
            let match = MVFixtureURLProtocol.route(method: "GET", path: path)
            XCTAssertEqual(match.status, 200, path)
            return match.body()
        }
        XCTAssertEqual(try decoder.decode([AccountResponse].self, from: body("/api/accounts")).count, 1)
        XCTAssertEqual(try decoder.decode([IdentityResponse].self, from: body("/api/identities")).count, 2)
        let message = try decoder.decode(MessageDetail.self, from: body("/api/messages/\(ComposeFixtures.messageId)"))
        XCTAssertEqual(message.subject, "Dinner on Friday")
        XCTAssertEqual(
            try decoder.decode(
                MessageQuoteResponse.self, from: body("/api/messages/\(ComposeFixtures.messageId)/quote")
            )
            .html, ComposeFixtures.quoteHTML)
        XCTAssertEqual(try decoder.decode([ContactSearchHitOut].self, from: body("/api/contacts/search")).count, 1)
    }
}
