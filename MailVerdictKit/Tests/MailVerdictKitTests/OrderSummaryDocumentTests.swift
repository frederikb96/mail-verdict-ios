import XCTest
@testable import MailVerdictKit

final class OrderSummaryDocumentTests: XCTestCase {

    func testASingleLineIsOneParagraph() {
        let blocks = OrderSummaryDocument.parse("Order confirmed.")
        XCTAssertEqual(blocks, [.paragraph([.init(text: "Order confirmed.", bold: false)])])
    }

    func testABlankLineBreaksAParagraph() {
        let blocks = OrderSummaryDocument.parse("First.\n\nSecond.")
        XCTAssertEqual(
            blocks,
            [
                .paragraph([.init(text: "First.", bold: false)]),
                .paragraph([.init(text: "Second.", bold: false)]),
            ])
    }

    func testConsecutiveLinesWithoutABlankJoinOneParagraphWithASpace() {
        let blocks = OrderSummaryDocument.parse("First line\nsecond line")
        XCTAssertEqual(blocks, [.paragraph([.init(text: "First line second line", bold: false)])])
    }

    func testADashPrefixedLineIsABullet() {
        let blocks = OrderSummaryDocument.parse("- Ordered on 12 Apr\n- Delivered on 15 Apr")
        XCTAssertEqual(
            blocks,
            [
                .bullets([
                    [.init(text: "Ordered on 12 Apr", bold: false)],
                    [.init(text: "Delivered on 15 Apr", bold: false)],
                ])
            ])
    }

    func testAnAsteriskPrefixedLineIsAlsoABullet() {
        let blocks = OrderSummaryDocument.parse("* One item")
        XCTAssertEqual(blocks, [.bullets([[.init(text: "One item", bold: false)]])])
    }

    func testBoldMarkersProduceABoldRun() {
        let blocks = OrderSummaryDocument.parse("Total: **EUR 49.90**")
        XCTAssertEqual(
            blocks,
            [
                .paragraph([
                    .init(text: "Total: ", bold: false),
                    .init(text: "EUR 49.90", bold: true),
                ])
            ])
    }

    func testAnUnmatchedOpeningMarkerIsKeptAsLiteralText() {
        let blocks = OrderSummaryDocument.parse("Odd **marker")
        XCTAssertEqual(
            blocks,
            [
                .paragraph([
                    .init(text: "Odd ", bold: false),
                    .init(text: "**", bold: false),
                    .init(text: "marker", bold: false),
                ])
            ])
    }

    func testHeadingsLinksAndAnglesAreNeverInterpretedAsMarkup() {
        let blocks = OrderSummaryDocument.parse("# Not a heading, [not a link](url), <not html>")
        XCTAssertEqual(
            blocks,
            [.paragraph([.init(text: "# Not a heading, [not a link](url), <not html>", bold: false)])])
    }

    func testAParagraphThenABulletListAreSeparateBlocks() {
        let blocks = OrderSummaryDocument.parse("Summary line.\n- one\n- two")
        XCTAssertEqual(
            blocks,
            [
                .paragraph([.init(text: "Summary line.", bold: false)]),
                .bullets([[.init(text: "one", bold: false)], [.init(text: "two", bold: false)]]),
            ])
    }

    func testEmptyTextProducesNoBlocks() {
        XCTAssertEqual(OrderSummaryDocument.parse(""), [])
    }
}
