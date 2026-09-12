import XCTest

@testable import MailVerdictKit

final class ReaderLinksTests: XCTestCase {

    func testEveryControlLinkSurvivesTheWebViewRoundTrip() throws {
        let id = UUID()
        let other = UUID()
        let links: [MVReaderLink] = [
            .address(messageId: id, field: .cc, index: 2), .attachment(messageId: id, attachmentId: other),
            .shareAttachment(messageId: id, attachmentId: other), .images(messageId: id, choice: .domain),
            .draft(messageId: id), .retry, .invitation(messageId: id, action: .addToCalendar),
            .invitation(messageId: id, action: .toggleAlwaysUse),
            .invitation(messageId: id, action: .respond(.declined)),
            .invitation(messageId: id, action: .sendAgain), .invitation(messageId: id, action: .note),
            .invitation(messageId: id, action: .eventDetails), .invitation(messageId: id, action: .confirmChange),
            .invitation(messageId: id, action: .retry),
        ]
        for link in links {
            let url = try XCTUnwrap(URL(string: link.url))
            XCTAssertEqual(MVReaderLink(url: url), link, link.url)
        }
    }

    func testMalformedControlLinksAreRefused() {
        XCTAssertNil(MVReaderLink(url: URL(string: "mv://attachment/not-a-uuid/x")!))
        XCTAssertNil(MVReaderLink(url: URL(string: "mv://unknown/\(UUID())")!))
        XCTAssertNil(MVReaderLink(url: URL(string: "https://attachment/\(UUID())/\(UUID())")!))
    }

    /// Only a person's tap may leave the page — a message cannot navigate it by itself.
    func testNavigationClassification() {
        let web = URL(string: "https://example.org/a")!
        XCTAssertEqual(MVReaderNavigation.classify(web, isUserAction: true), .web(web))
        XCTAssertEqual(MVReaderNavigation.classify(web, isUserAction: false), .ignore)
        XCTAssertEqual(MVReaderNavigation.classify(URL(string: "about:blank")!, isUserAction: false), .allow)
        XCTAssertEqual(MVReaderNavigation.classify(URL(string: "about:blank#toc")!, isUserAction: true), .anchor("toc"))
        XCTAssertEqual(MVReaderNavigation.classify(URL(string: "javascript:alert(1)")!, isUserAction: true), .ignore)
        let mail = URL(string: "mailto:a@example.org")!
        XCTAssertEqual(MVReaderNavigation.classify(mail, isUserAction: true), .mailto(mail))
        XCTAssertEqual(MVReaderNavigation.classify(URL(string: "mv://retry")!, isUserAction: true), .control(.retry))
    }

    /// WebKit compiles these at launch; a list that is not valid JSON fails there, silently
    /// leaving every page unprotected.
    func testContentRuleListsAreValidJSON() throws {
        let strict = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(ReaderContentRules.strict.utf8)) as? [[String: Any]])
        let images = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(ReaderContentRules.imagesAllowed.utf8)) as? [[String: Any]])
        XCTAssertEqual((strict.first?["action"] as? [String: String])?["type"], "block")
        XCTAssertEqual(images.count, strict.count + 1)
        let lastTrigger = try XCTUnwrap(images.last?["trigger"] as? [String: Any])
        XCTAssertEqual(lastTrigger["resource-type"] as? [String], ["image"])
    }

    /// The app calls `reader.js` by name; a function renamed on one side only would fail inside
    /// the web view with nothing to show for it.
    func testEveryFunctionTheAppCallsIsExposedByTheScript() throws {
        let source = ReaderScript.source
        XCTAssertFalse(source.isEmpty, "reader.js resource did not load")
        let line = try XCTUnwrap(source.components(separatedBy: "\n").first { $0.contains("window.mvReader = {") })
        let body = try XCTUnwrap(line.split(separator: "{", maxSplits: 1).last?.split(separator: "}").first)
        let exposed = Set(
            body.split(separator: ",").map { $0.split(separator: ":").first!.trimmingCharacters(in: .whitespaces) })
        for function in ReaderScript.Function.allCases {
            XCTAssertTrue(exposed.contains(function.rawValue), function.rawValue)
        }
    }

    func testFixtureThreadsSurviveTheAPIsOwnCoding() throws {
        for (_, thread) in ReaderFixtures.threads() {
            let data = try JSONEncoder.mvDefault.encode(thread)
            XCTAssertEqual(try JSONDecoder.mvDefault.decode(ThreadResponse.self, from: data), thread)
        }
        let invitation = try JSONEncoder.mvDefault.encode(ReaderFixtures.importedInvitation)
        XCTAssertEqual(
            try JSONDecoder.mvDefault.decode(Invitation.self, from: invitation), ReaderFixtures.importedInvitation)
    }
}
