import XCTest

@testable import MailVerdictKit

final class ReaderBodyPipelineTests: XCTestCase {

    // MARK: Sanitizer

    func testScriptAndTemplateLeaveWithTheirContent() {
        let out = MessageHTMLSanitizer.sanitize(
            #"<p>kept</p><script>alert(1)</script><template><p>hidden</p></template>"#)
        XCTAssertTrue(out.contains("kept"))
        XCTAssertFalse(out.contains("alert"))
        XCTAssertFalse(out.contains("hidden"))
        XCTAssertFalse(out.lowercased().contains("template"))
    }

    /// A body sits inside a declarative shadow root's `<template>`; a literal end tag reaching the
    /// page would close it early and let the rest of the message out into the chrome.
    func testStrayTemplateEndTagCannotLeaveTheShadowRoot() {
        let out = MessageHTMLSanitizer.sanitize(#"<p>a</template><b>b</b></p><div>&lt;/template&gt;</div>"#)
        XCTAssertFalse(out.contains("</template>"), out)
        XCTAssertTrue(out.contains("&lt;/template&gt;"), out)
    }

    func testUnknownElementIsUnwrappedKeepingItsText() {
        XCTAssertEqual(MessageHTMLSanitizer.sanitize("<blink>hello</blink>"), "hello")
    }

    func testEventHandlersAndScriptURLsAreDropped() {
        let out = MessageHTMLSanitizer.sanitize(
            #"<a href="javascript:alert(1)" onclick="x()">t</a><img src="https://a.example/x.png" onerror="y()">"#)
        XCTAssertFalse(out.contains("javascript"))
        XCTAssertFalse(out.contains("onclick"))
        XCTAssertFalse(out.contains("onerror"))
        XCTAssertTrue(out.contains(#"src="https://a.example/x.png""#))
    }

    /// An element carrying a single attribute is the shape SwiftSoup's own serializer re-emits
    /// from its source text after the attribute was changed; the writer must never let it through.
    func testALoneDangerousAttributeIsDropped() {
        XCTAssertEqual(MessageHTMLSanitizer.sanitize(#"<img src="javascript:alert(1)">"#), "<img>")
        XCTAssertEqual(MessageHTMLSanitizer.sanitize(#"<p onclick="x()">t</p>"#), "<p>t</p>")
    }

    func testSchemeHiddenBehindWhitespaceIsStillDropped() {
        XCTAssertEqual(MessageHTMLSanitizer.sanitize("<a href=\"java\tscript:alert(1)\">t</a>"), "<a>t</a>")
    }

    func testDataURIsAreAllowedOnImagesOnly() {
        XCTAssertTrue(
            MessageHTMLSanitizer.sanitize(#"<img src="data:image/png;base64,AAAA">"#).contains("data:image/png"))
        XCTAssertFalse(MessageHTMLSanitizer.sanitize(#"<a href="data:text/html,hi">t</a>"#).contains("data:"))
    }

    /// A template's own dark-mode stylesheet often comes before any visible markup — the reason
    /// the web passes `FORCE_BODY`.
    func testLeadingStyleBlockIsKept() {
        XCTAssertTrue(
            MessageHTMLSanitizer.sanitize(#"<style>.a{color:red}</style><p class="a">x</p>"#).hasPrefix("<style>"))
    }

    func testAttributeValueThatCouldEndARawTextElementIsDropped() {
        XCTAssertFalse(MessageHTMLSanitizer.sanitize(#"<p title="</style><b>x</b>">t</p>"#).contains("title"))
    }

    // MARK: Quote collapsing

    func testOnlyTheFirstReplyQuoteIsCollapsed() {
        let out = QuoteCollapser.collapse(
            #"<p>top</p><blockquote type="cite">one<blockquote type="cite">nested</blockquote></blockquote><blockquote type="cite">two</blockquote>"#
        )
        XCTAssertEqual(out.components(separatedBy: "<details").count - 1, 1)
        XCTAssertTrue(out.hasPrefix("<p>top</p><details"))
        XCTAssertTrue(out.hasSuffix(#"</details><blockquote type="cite">two</blockquote>"#))
    }

    func testClassOnAnAncestorMarksAReplyQuote() {
        XCTAssertTrue(
            QuoteCollapser.collapse(#"<div class="gmail_quote"><div><blockquote>q</blockquote></div></div>"#)
                .contains("<details"))
    }

    func testAnOrdinaryQuotationStaysVisible() {
        XCTAssertFalse(QuoteCollapser.collapse("<blockquote>pull quote</blockquote>").contains("<details"))
    }

    // MARK: Colour-scheme queries

    func testColorSchemeQueriesAnswerToTheCanvas() {
        let css = "@media screen and (prefers-color-scheme: dark) { a {} } @media (prefers-color-scheme:light) { b {} }"
        XCTAssertEqual(
            ColorSchemeQueryAligner.align(css, canvas: .dark),
            "@media screen and (min-width: 0px) { a {} } @media (max-width: 0px) { b {} }")
        XCTAssertEqual(
            ColorSchemeQueryAligner.align(css, canvas: .light),
            "@media screen and (max-width: 0px) { a {} } @media (min-width: 0px) { b {} }")
    }

    func testStyleMediaAttributeIsAlignedToo() {
        let rendering = MessageBodyRenderer.render(
            bodyHTML: #"<style media="(prefers-color-scheme: dark)">p{color:#fff}</style><p>x</p>"#, bodyText: nil,
            theme: .light, manualCanvas: nil)
        XCTAssertTrue(rendering.shadowContent.contains(#"media="(max-width: 0px)""#))
    }

    // MARK: Plain text

    func testALinkCannotCloseItsOwnAttribute() {
        let out = PlainTextLinkifier.render(#"see http://evil.example/"onmouseover="alert(1) now"#)
        XCTAssertTrue(out.contains(#"href="http://evil.example/""#))
        XCTAssertTrue(out.contains("&quot;onmouseover=&quot;"))
        XCTAssertFalse(out.contains(#""onmouseover"#))
    }

    func testPlainTextMarkupIsEscaped() {
        XCTAssertTrue(PlainTextLinkifier.render("<b>hi</b>").contains("&lt;b&gt;hi&lt;/b&gt;"))
    }

    // MARK: Renderer

    func testInlineImagesPointAtTheReaderScheme() {
        let message = UUID()
        let attachment = UUID()
        XCTAssertNotNil(
            MessageBodyRenderer.rewrittenAttachmentURL("/api/messages/\(message)/attachments/\(attachment)"),
            "path helper")
        let rendering = MessageBodyRenderer.render(
            bodyHTML: #"<p><img src="/api/messages/\#(message)/attachments/\#(attachment)"></p>"#, bodyText: nil,
            theme: .light, manualCanvas: nil)
        XCTAssertTrue(
            rendering.shadowContent.contains(
                "mv-attachment://\(message.uuidString.lowercased())/\(attachment.uuidString.lowercased())"),
            rendering.shadowContent.components(separatedBy: "</style>").last ?? "")
    }

    func testPlainTextFollowsTheTheme() {
        let rendering = MessageBodyRenderer.render(bodyHTML: nil, bodyText: "hi", theme: .dark, manualCanvas: .light)
        XCTAssertEqual(rendering.canvas, .dark)
        XCTAssertFalse(rendering.isHTML)
    }

    func testManualCanvasOverridesThePicker() {
        let html = "<style>@media (prefers-color-scheme: dark) { p { color: #fff } }</style><p>x</p>"
        XCTAssertEqual(
            MessageBodyRenderer.render(bodyHTML: html, bodyText: nil, theme: .dark, manualCanvas: nil).canvas, .dark)
        XCTAssertEqual(
            MessageBodyRenderer.render(bodyHTML: html, bodyText: nil, theme: .dark, manualCanvas: .light).canvas, .light
        )
    }
}
