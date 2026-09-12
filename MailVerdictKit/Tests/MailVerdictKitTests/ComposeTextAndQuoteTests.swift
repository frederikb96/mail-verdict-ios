import Foundation
import XCTest

@testable import MailVerdictKit

final class ComposeTextAndQuoteTests: XCTestCase {

    func testTextExportNumbersNestedListsAndMarksChecklists() {
        let document = ComposeDocument(blocks: [
            ComposeBlock(.listItem(.ordered, level: 0, checked: false), [.text("first")]),
            ComposeBlock(.listItem(.bullet, level: 1, checked: false), [.text("nested")]),
            ComposeBlock(.listItem(.ordered, level: 0, checked: false), [.text("second")]),
            ComposeBlock(.paragraph),
            ComposeBlock(.listItem(.checklist, level: 0, checked: true), [.text("done")]),
            ComposeBlock(.listItem(.checklist, level: 0, checked: false), [.text("open")]),
            ComposeBlock(.quote, [.text("said")]),
            ComposeBlock(.codeBlock, [.text("x = 1")]),
        ])
        XCTAssertEqual(
            ComposeTextSerializer.text(document),
            """
            1. first
              - nested
            2. second

            - [x] done
            - [ ] open
            > said
            ```
            x = 1
            ```
            """)
    }

    func testTextExportOpensAndClosesMarksWhereTheyChange() {
        let document = ComposeDocument(blocks: [
            ComposeBlock(
                .paragraph,
                [
                    .text("a ", [.bold]), .text("b", [.bold, .italic]), .text(" c", [.bold]),
                    .text(" see ", link: nil), .text("site", link: "https://x.test"),
                ])
        ])
        XCTAssertEqual(ComposeTextSerializer.text(document), "**a *b* c** see [site](https://x.test)")
    }

    /// The shape the quote endpoint hands back for a saved draft: the server's sanitizer keeps
    /// the classes and drops the composer's own data attribute.
    func testSplitFindsTheSanitizedQuoteWrapperAndItsMultilineAttribution() {
        let html = """
            <p>My reply</p><div class="gmail_quote"><div class="gmail_attr">---------- Forwarded message ----------<br>From: a@b.test</div>\
            <blockquote class="gmail_quote" style="margin:0"><p>Original <b>text</b></p></blockquote></div>
            """
        let split = ComposeQuoteSplitter.split(html)
        XCTAssertEqual(split.quote?.attribution, "---------- Forwarded message ----------\nFrom: a@b.test")
        XCTAssertEqual(split.quote?.html, "<p>Original <b>text</b></p>")
        XCTAssertEqual(ComposeHTMLParser.parse(split.body).document.blocks.map(\.plainText), ["My reply"])
    }

    func testWrittenQuoteSplitsBackToTheSameQuote() {
        let quote = ComposeQuote(
            html: "<p>Hi &amp; bye</p>", attribution: "On Mon, 1 Jan 2024, 10:00, Ann <ann@x.test> wrote:")
        let body = ComposeHTMLSerializer.body(
            ComposeDocument(blocks: [ComposeBlock(.paragraph, [.text("Thanks")])]), quote: quote)
        let split = ComposeQuoteSplitter.split(body ?? "")
        XCTAssertEqual(split.quote, quote)
    }

    func testBodyIsNilOnlyWhenThereIsNeitherTextNorQuote() {
        XCTAssertNil(ComposeHTMLSerializer.body(.empty, quote: nil))
        XCTAssertNotNil(ComposeHTMLSerializer.body(.empty, quote: ComposeQuote(html: "<p>x</p>", attribution: "a")))
    }

    func testDraftQuotedTextStartsAtTheAttribution() {
        let bodyText = "Hello\n\nOn Mon, Ann wrote:\n> old line"
        XCTAssertEqual(
            ComposeReply.draftQuotedText(bodyText: bodyText, attribution: "On Mon, Ann wrote:"),
            "\n\nOn Mon, Ann wrote:\n> old line")
        XCTAssertEqual(ComposeReply.draftQuotedText(bodyText: bodyText, attribution: "On Tue, Bob wrote:"), "")
    }
}
