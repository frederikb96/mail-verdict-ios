import XCTest
@testable import MailVerdictKit

final class MailtoTests: XCTestCase {

    func testPlainAddressInThePath() {
        let link = parseMailto("mailto:a@example.com")
        XCTAssertEqual(link?.to, ["a@example.com"])
    }

    func testQueryParametersFillCcBccSubjectAndBody() {
        let link = parseMailto("mailto:a@example.com?cc=b@example.com&bcc=c@example.com&subject=Hi&body=Hello")
        XCTAssertEqual(link?.to, ["a@example.com"])
        XCTAssertEqual(link?.cc, ["b@example.com"])
        XCTAssertEqual(link?.bcc, ["c@example.com"])
        XCTAssertEqual(link?.subject, "Hi")
        XCTAssertEqual(link?.bodyHtml, "<p>Hello</p>")
    }

    /// The path and the `to=` parameter may both name recipients — the union is what the sender
    /// meant, de-duplicated rather than one source winning.
    func testPathAndToParameterAreMergedAndDeduplicated() {
        let link = parseMailto("mailto:a@example.com?to=a@example.com,b@example.com")
        XCTAssertEqual(link?.to, ["a@example.com", "b@example.com"])
    }

    func testNotMailtoReturnsNil() {
        XCTAssertNil(parseMailto("https://example.com"))
    }

    func testEmptyMailtoWithNoFieldsReturnsNil() {
        XCTAssertNil(parseMailto("mailto:"))
    }

    func testBlankLineSeparatedBodySplitsIntoParagraphs() {
        let link = parseMailto("mailto:?body=line%20one%0A%0Aline%20two")
        XCTAssertEqual(link?.bodyHtml, "<p>line one</p><p>line two</p>")
    }

    func testSingleNewlineInBodyBecomesABreak() {
        let link = parseMailto("mailto:?body=line%20one%0Aline%20two")
        XCTAssertEqual(link?.bodyHtml, "<p>line one<br>line two</p>")
    }

    func testHtmlSpecialCharactersInBodyAreEscaped() {
        let link = parseMailto("mailto:?body=%3Cb%3E%26%3C%2Fb%3E")
        XCTAssertEqual(link?.bodyHtml, "<p>&lt;b&gt;&amp;&lt;/b&gt;</p>")
    }

    /// A trailing or doubled comma is common enough in real links to be worth surviving.
    func testTrailingAndDoubledCommasInAddressListsAreIgnored() {
        let link = parseMailto("mailto:?to=a@example.com,,b@example.com,")
        XCTAssertEqual(link?.to, ["a@example.com", "b@example.com"])
    }
}
