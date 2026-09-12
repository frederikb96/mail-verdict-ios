import XCTest
@testable import MailVerdictKit

final class BoldMarkersTests: XCTestCase {

    func testPlainTextWithNoMarkersIsOneSegment() {
        XCTAssertEqual(parseBoldMarkers("hello world"), [MVTextSegment(text: "hello world", isBold: false)])
    }

    func testOneBoldSpanInTheMiddle() {
        XCTAssertEqual(
            parseBoldMarkers("before **bold** after"),
            [
                MVTextSegment(text: "before ", isBold: false),
                MVTextSegment(text: "bold", isBold: true),
                MVTextSegment(text: " after", isBold: false),
            ]
        )
    }

    func testMultipleBoldSpans() {
        XCTAssertEqual(
            parseBoldMarkers("a **b** c **d** e"),
            [
                MVTextSegment(text: "a ", isBold: false),
                MVTextSegment(text: "b", isBold: true),
                MVTextSegment(text: " c ", isBold: false),
                MVTextSegment(text: "d", isBold: true),
                MVTextSegment(text: " e", isBold: false),
            ]
        )
    }

    func testBoldAtTheVeryStart() {
        XCTAssertEqual(
            parseBoldMarkers("**bold** rest"),
            [MVTextSegment(text: "bold", isBold: true), MVTextSegment(text: " rest", isBold: false)]
        )
    }

    func testEmptyStringIsNoSegments() {
        XCTAssertEqual(parseBoldMarkers(""), [])
    }

    /// A fixed-length excerpt can genuinely truncate mid-marker — the opening `**` with no
    /// closer is literal text, never an unterminated bold run.
    func testAnUnmatchedTrailingMarkerIsLiteral() {
        XCTAssertEqual(
            parseBoldMarkers("before **bold"),
            [
                MVTextSegment(text: "before ", isBold: false), MVTextSegment(text: "**", isBold: false),
                MVTextSegment(text: "bold", isBold: false),
            ]
        )
    }

    func testAdjacentBoldSpansWithNoTextBetween() {
        XCTAssertEqual(
            parseBoldMarkers("**a****b**"),
            [MVTextSegment(text: "a", isBold: true), MVTextSegment(text: "b", isBold: true)]
        )
    }
}
