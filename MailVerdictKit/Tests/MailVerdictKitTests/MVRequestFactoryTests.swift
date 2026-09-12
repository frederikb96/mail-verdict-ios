import XCTest
@testable import MailVerdictKit

/// These cover the rules that are easy to break and silent when broken — the scheme guard, the
/// trailing-slash join, and reading the token at send time rather than at construction. Straight
/// URL concatenation is not tested; it would pass without proving anything.
final class MVRequestFactoryTests: XCTestCase {

    func testRejectsNonHttpScheme() {
        XCTAssertThrowsError(
            try MVRequestFactory(baseURL: "ftp://example.com", authProvider: { .none })
        ) { error in
            XCTAssertEqual(
                error as? MVRequestFactory.ConfigurationError,
                .unsupportedScheme("ftp")
            )
        }
    }

    func testRejectsEmptyBaseURL() {
        XCTAssertThrowsError(
            try MVRequestFactory(baseURL: "   ", authProvider: { .none })
        ) { error in
            XCTAssertEqual(error as? MVRequestFactory.ConfigurationError, .emptyBaseURL)
        }
    }

    func testTrailingSlashDoesNotDoubleUp() throws {
        let factory = try MVRequestFactory(
            baseURL: "https://mail.example.com/",
            authProvider: { .none }
        )
        let request = try factory.makeRequest(path: "/api/health")
        XCTAssertEqual(request.url?.absoluteString, "https://mail.example.com/api/health")
    }

    /// The credential is read per request, so entering one in the connection screen takes effect
    /// immediately rather than on the next launch.
    func testTokenIsReadAtSendTimeNotConstructionTime() throws {
        let mode = AuthModeBox()
        let factory = try MVRequestFactory(
            baseURL: "https://mail.example.com",
            authProvider: { mode.value }
        )

        let before = try factory.makeRequest(path: "/api/health")
        XCTAssertNil(before.value(forHTTPHeaderField: "Authorization"))

        mode.value = .bearer(token: "jwt-value")
        let after = try factory.makeRequest(path: "/api/health")
        XCTAssertEqual(after.value(forHTTPHeaderField: "Authorization"), "Bearer jwt-value")
    }

    func testEmptyBearerTokenSendsNoAuthorizationHeader() throws {
        let factory = try MVRequestFactory(
            baseURL: "https://mail.example.com",
            authProvider: { .bearer(token: "") }
        )
        let request = try factory.makeRequest(path: "/api/health")
        XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
    }

    /// `echo -n user:pass | base64` — a fixed reference value, not re-derived from the same
    /// base64 call the implementation makes.
    func testBasicAuthSendsBase64EncodedCredentials() throws {
        let factory = try MVRequestFactory(
            baseURL: "https://mail.example.com",
            authProvider: { .basic(username: "user", password: "pass") }
        )
        let request = try factory.makeRequest(path: "/api/health")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Basic dXNlcjpwYXNz")
    }

    /// `URLComponents` leaves a literal `+` in a query value alone — it is a legal query
    /// character per RFC 3986 — but a server commonly decodes the query as
    /// `application/x-www-form-urlencoded`, where `+` means space. A folder name or search term
    /// containing `+` must round-trip as itself, not as a space.
    func testQueryValueEscapesLiteralPlusRatherThanLeavingItAsASpace() throws {
        let factory = try MVRequestFactory(
            baseURL: "https://mail.example.com", authProvider: { .none }
        )
        let request = try factory.makeRequest(
            path: "/api/search",
            query: [URLQueryItem(name: "q", value: "a+b")]
        )
        let raw = request.url?.absoluteString ?? ""
        XCTAssertTrue(raw.contains("q=a%2Bb"), raw)
        XCTAssertFalse(raw.contains("q=a+b"), raw)
    }

    /// Joins `baseURL.path` and `path` via `percentEncodedPath`, which passes an already-encoded
    /// path through untouched — the regression this guards is a return to
    /// `appendingPathComponent`, which would re-encode a pre-encoded segment (`%2F` becoming
    /// `%252F`).
    func testPreEncodedPathSegmentSurvivesWithoutBeingReEncoded() throws {
        let factory = try MVRequestFactory(
            baseURL: "https://mail.example.com", authProvider: { .none }
        )
        let request = try factory.makeRequest(path: "/api/folders/a%2Fb")
        let raw = request.url?.absoluteString ?? ""
        XCTAssertTrue(raw.hasSuffix("/api/folders/a%2Fb"), raw)
        XCTAssertFalse(raw.contains("%25"), raw)
    }
}

/// A `var` captured by an escaping sendable closure and mutated afterwards is a data race the
/// compiler cannot rule out, even where the test is single-threaded. A reference box makes the
/// sharing explicit instead of asserting it away.
private final class AuthModeBox: @unchecked Sendable {
    var value: MVAuthMode = .none
}
