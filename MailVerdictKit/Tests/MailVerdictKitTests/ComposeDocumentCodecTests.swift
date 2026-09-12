import Foundation
import XCTest

@testable import MailVerdictKit

/// The codecs every body goes through — paste, a reopened draft, an undone send, the editor's own
/// text — must agree with each other, or content changes shape each time it passes through one.
final class ComposeDocumentCodecTests: XCTestCase {

    private static let fixture = """
        <p>Hello <strong>bold <em>both</em></strong> and <a href="https://example.com/a?b=1&amp;c=2">a link</a></p>
        <h2>Title</h2>
        <p>line one<br>line two</p>
        <p></p>
        <ul><li><p>one</p><ol><li><p>sub</p></li><li><p>sub two</p></li></ol></li><li><p>two</p></li></ul>
        <ul data-type="taskList"><li data-checked="true" data-type="taskItem"><label><input type="checkbox" checked="checked"><span></span></label><div><p>done</p></div></li>\
        <li data-checked="false" data-type="taskItem"><label><input type="checkbox"><span></span></label><div><p>open</p></div></li></ul>
        <blockquote><p>quoted one</p><p>quoted two</p></blockquote>
        <pre><code>let a = 1

        let b = 2</code></pre>
        <p><u>under</u> <s>struck</s> <img src="cid:img1" alt="chart" width="320"></p>
        """

    private func parse(_ html: String) -> ComposeDocument {
        ComposeHTMLParser.parse(html, makeContentId: { "generated" }).document
    }

    func testParserReadsEveryBlockKindTheEditorHas() {
        let kinds = parse(Self.fixture).blocks.map(\.kind)
        XCTAssertEqual(
            kinds,
            [
                .paragraph, .heading(level: 2), .paragraph, .paragraph,
                .listItem(.bullet, level: 0, checked: false), .listItem(.ordered, level: 1, checked: false),
                .listItem(.ordered, level: 1, checked: false), .listItem(.bullet, level: 0, checked: false),
                .listItem(.checklist, level: 0, checked: true), .listItem(.checklist, level: 0, checked: false),
                .quote, .quote, .codeBlock, .codeBlock, .codeBlock, .paragraph,
            ])
        let blocks = parse(Self.fixture).blocks
        XCTAssertEqual(blocks[2].runs, [.text("line one"), ComposeRun(.lineBreak), .text("line two")])
        XCTAssertEqual(blocks[3].runs, [], "an empty <p> is a blank line someone typed")
        XCTAssertEqual(blocks[13].plainText, "", "a blank line inside a code block survives")
        XCTAssertEqual(
            blocks[0].runs.last, .text("a link", link: "https://example.com/a?b=1&c=2"))
        XCTAssertTrue(
            blocks[15].runs.contains(ComposeRun(.image(ComposeImageRef(contentId: "img1", width: "320", alt: "chart"))))
        )
    }

    /// Serialize → parse → serialize must be a fixed point, or a draft saved and reopened drifts
    /// a little further from what was written every time.
    func testHTMLRoundTripIsStable() {
        let first = parse(Self.fixture)
        let html = ComposeHTMLSerializer.html(first)
        let second = parse(html)
        XCTAssertEqual(second, first)
        XCTAssertEqual(ComposeHTMLSerializer.html(second), html)
    }

    /// The editor holds the body as an attributed string; converting there and back must not
    /// change the document, or the dirty check reports edits nobody made.
    func testAttributedRoundTripPreservesTheDocument() {
        let document = parse(Self.fixture)
        let attributed = ComposeAttributedCodec.attributedString(from: document)
        XCTAssertEqual(
            ComposeAttributedCodec.document(from: attributed, trailingBlock: document.blocks.last?.kind), document)
    }

    func testEmptyTrailingListItemKeepsItsKindThroughTypingAttributes() {
        let document = ComposeDocument(blocks: [
            ComposeBlock(.listItem(.bullet, level: 0, checked: false), [.text("a")]),
            ComposeBlock(.listItem(.bullet, level: 0, checked: false)),
        ])
        let attributed = ComposeAttributedCodec.attributedString(from: document)
        XCTAssertEqual(attributed.string, "a\n")
        XCTAssertEqual(
            ComposeAttributedCodec.document(
                from: attributed, trailingBlock: .listItem(.bullet, level: 0, checked: false)),
            document)
    }

    func testBrowserChecklistPasteBecomesChecklistItems() {
        let blocks = parse(
            #"<ul><li><input type="checkbox" checked disabled> Buy milk</li><li><input type="checkbox"> Call Ann</li></ul>"#
        ).blocks
        XCTAssertEqual(
            blocks.map(\.kind),
            [
                .listItem(.checklist, level: 0, checked: true), .listItem(.checklist, level: 0, checked: false),
            ])
        XCTAssertEqual(blocks.map(\.plainText), ["Buy milk", "Call Ann"])
    }

    /// The server's outbound sanitizer turns checklist items into ballot-box glyphs, so that is
    /// the shape a saved draft comes back in.
    func testSanitizedChecklistGlyphsReadBackAsChecklist() {
        let blocks = parse("<ul><li>\u{2611}\u{00A0}Done</li><li>\u{2610}\u{00A0}Todo</li></ul>").blocks
        XCTAssertEqual(
            blocks.map(\.kind),
            [
                .listItem(.checklist, level: 0, checked: true), .listItem(.checklist, level: 0, checked: false),
            ])
        XCTAssertEqual(blocks.map(\.plainText), ["Done", "Todo"])
    }

    func testTableBecomesOneTabSeparatedParagraphPerRow() {
        let blocks = parse("<table><tr><th>Name</th><th>Qty</th></tr><tr><td><p>Apples</p></td><td>3</td></tr></table>")
            .blocks
        XCTAssertEqual(blocks.map(\.plainText), ["Name\tQty", "Apples\t3"])
    }

    func testDataImageBecomesAnInlineAttachmentRatherThanBase64() {
        let png = Data([0x89, 0x50, 0x4E, 0x47])
        let result = ComposeHTMLParser.parse(
            "<p>see <img src=\"data:image/png;base64,\(png.base64EncodedString())\"></p>", makeContentId: { "cid42" })
        XCTAssertEqual(
            result.images,
            [
                ComposeInlineImage(
                    contentId: "cid42", filename: "pasted-image-1.png", contentType: "image/png", data: png)
            ])
        XCTAssertEqual(result.document.referencedContentIds, ["cid42"])
        XCTAssertFalse(ComposeHTMLSerializer.html(result.document).contains("base64"))
    }

    func testInlineStylesAreReadAfterTagMarks() {
        let runs = parse(
            #"<b style="font-weight:normal"><span style="font-weight:700">bold</span> plain</b>"#
        ).blocks[0].runs
        XCTAssertEqual(runs, [.text("bold", [.bold]), .text(" plain")])
    }

    func testUnsafeLinkKeepsItsTextAndLosesTheTarget() {
        XCTAssertEqual(parse(#"<a href="javascript:alert(1)">click</a>"#).blocks[0].runs, [.text("click")])
    }

    func testWhitespaceCollapsesAsHTMLRendersIt() {
        XCTAssertEqual(parse("<p>  a \n   b  </p>").blocks[0].runs, [.text("a b")])
    }
}
