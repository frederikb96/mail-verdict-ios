#if DEBUG

    import XCTest
    @testable import MailVerdictKit

    final class MVFixtureURLProtocolTests: XCTestCase {

        override func tearDown() {
            MVFixtureURLProtocol.resetToDefaults()
            super.tearDown()
        }

        /// The mechanism a feature slice's own store or screen file uses to add its fixtures —
        /// never by editing this shared file.
        func testARegisteredRouteAnswersWithItsOwnBodyAndStatus() {
            MVFixtureURLProtocol.register(method: "GET", path: "/api/accounts", status: 200) {
                Data("[]".utf8)
            }
            let match = MVFixtureURLProtocol.route(method: "GET", path: "/api/accounts")
            XCTAssertEqual(match.status, 200)
            XCTAssertEqual(String(decoding: match.body(), as: UTF8.self), "[]")
        }

        /// A later registration for the same method and path wins outright, rather than the two
        /// somehow coexisting or the first staying stuck forever.
        func testRegisteringTheSameRouteTwiceReplacesIt() {
            MVFixtureURLProtocol.register(method: "GET", path: "/api/accounts") { Data("[]".utf8) }
            MVFixtureURLProtocol.register(method: "GET", path: "/api/accounts") { Data("[1]".utf8) }
            let match = MVFixtureURLProtocol.route(method: "GET", path: "/api/accounts")
            XCTAssertEqual(String(decoding: match.body(), as: UTF8.self), "[1]")
        }

        func testKnownRouteAnswers200WithItsBody() {
            let match = MVFixtureURLProtocol.route(method: "GET", path: "/api/health")
            XCTAssertEqual(match.status, 200)
            let body = String(decoding: match.body(), as: UTF8.self)
            XCTAssertTrue(body.contains("\"ready\""), body)
        }

        /// An unmatched route answers the same `{"detail": ...}` shape every real error path
        /// already parses, rather than an empty or malformed body a decoder would choke on —
        /// that is what lets a screen under development fail readably instead of crashing on a
        /// decode error that points nowhere near the missing fixture.
        func testUnknownRouteAnswers404WithADetailBody() {
            let match = MVFixtureURLProtocol.route(method: "GET", path: "/api/nonexistent")
            XCTAssertEqual(match.status, 404)
            let body = String(decoding: match.body(), as: UTF8.self)
            XCTAssertNoThrow(try JSONDecoder().decode(FixtureErrorBody.self, from: match.body()))
            XCTAssertTrue(body.contains("/api/nonexistent"), body)
        }

        /// The method is part of the route identity — a fixture registered for GET must not
        /// answer a POST to the same path with the same body, the same rule the debug bridge's
        /// own router enforces for the same reason.
        func testMethodIsPartOfTheRouteIdentity() {
            let match = MVFixtureURLProtocol.route(method: "POST", path: "/api/health")
            XCTAssertEqual(match.status, 404)
        }
    }

    private struct FixtureErrorBody: Decodable {
        let detail: String
    }

#endif
