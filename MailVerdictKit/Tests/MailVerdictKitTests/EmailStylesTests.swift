import XCTest

@testable import MailVerdictKit

final class EmailStylesTests: XCTestCase {

    /// The reader's chrome (subject, sender, date) already tracks Dynamic Type through the
    /// `-apple-system-*` font keywords (`ConversationDocumentBuilder`'s own stylesheet). A message
    /// body that inherits a fixed pixel `:host` font-size instead never grows with it, so a large
    /// text size user gets native-looking chrome around a body stuck at the default.
    func testHostFontSizeIsNotAFixedPixelValue() throws {
        for canvas in MVCanvas.allCases {
            let host = try hostRule(in: EmailStyles.css(for: canvas))
            XCTAssertNil(
                host.range(of: #"font-size\s*:\s*\d"#, options: .regularExpression),
                "\(canvas): :host sets a fixed-size font-size, which never scales with Dynamic Type")
        }
    }

    private func hostRule(in css: String) throws -> String {
        let start = try XCTUnwrap(css.range(of: ":host {"), "no :host rule in the stylesheet")
        let end = try XCTUnwrap(
            css.range(of: "}", range: start.upperBound..<css.endIndex), "unterminated :host rule")
        return String(css[start.upperBound..<end.lowerBound])
    }
}
