import XCTest
@testable import MailVerdictKit

final class MVErrorTests: XCTestCase {

    func testErrorPrefersServerDetailOverStatusLine() {
        let body = Data(#"{"detail":"account not found"}"#.utf8)
        XCTAssertEqual(MVError.from(statusCode: 404, body: body).userMessage, "account not found")
    }

    func testErrorFallsBackToStatusLineOnNonJsonBody() {
        let error = MVError.from(statusCode: 502, body: Data("<html>".utf8))
        XCTAssertTrue(error.userMessage.hasPrefix("HTTP 502:"))
    }

    /// `.decoding`'s own associated text is a `DecodingError`'s raw, verbose description, built
    /// from `"\(error)"` at every call site — never what a screen shows.
    func testDecodingErrorNeverShowsTheRawDescriptionItCarries() {
        let raw = #"Swift.DecodingError.typeMismatch(Swift.String, ...)"#
        XCTAssertFalse(MVError.decoding(raw).userMessage.contains(raw))
    }

    /// This is the one property every call site actually branches on — whether the credential,
    /// not the request, was the problem — so a future status code added here has to be
    /// classified correctly or a rejected token silently reads as an ordinary failure.
    func testOnlyAuthenticationStatusesAreClassifiedAsAuthFailures() {
        XCTAssertTrue(MVError.detail("nope", statusCode: 401).isAuthenticationFailure)
        XCTAssertTrue(MVError.detail("nope", statusCode: 403).isAuthenticationFailure)
        XCTAssertFalse(MVError.detail("nope", statusCode: 404).isAuthenticationFailure)
        XCTAssertFalse(MVError.transport("offline").isAuthenticationFailure)
        XCTAssertFalse(MVError.decoding("bad json").isAuthenticationFailure)
    }
}
