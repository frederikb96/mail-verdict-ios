import XCTest
@testable import MailVerdictKit

final class MVApiClientTests: XCTestCase {

    override func tearDown() {
        MVStubURLProtocol.reset()
        super.tearDown()
    }

    private func makeClient(onAuthenticationFailure: (@Sendable (MVError) -> Void)? = nil) throws -> MVApiClient {
        let factory = try MVRequestFactory(baseURL: "https://mail.example.com", authProvider: { .none })
        return MVApiClient(
            requestFactory: factory,
            urlSession: MVStubURLProtocol.makeSession(),
            onAuthenticationFailure: onAuthenticationFailure
        )
    }

    /// `/api/health` answers the SAME body shape whether ready (200) or not (503) — the
    /// regression this guards is `getHealth()` going back to a plain `send()`, which would throw
    /// away exactly the diagnostic the 503 body carries.
    func testGetHealthDecodesTheReadyBody() async throws {
        MVStubURLProtocol.stub = .init(
            statusCode: 200, headers: [:],
            body: Data(#"{"status":"ready","postimap_contract":"ok","database":"ok"}"#.utf8)
        )
        let health = try await makeClient().getHealth()
        XCTAssertTrue(health.isReady)
        XCTAssertEqual(health.database, "ok")
    }

    func testGetHealthDecodesTheNotReadyBodyRatherThanThrowing() async throws {
        MVStubURLProtocol.stub = .init(
            statusCode: 503, headers: [:],
            body: Data(#"{"status":"not_ready","postimap_contract":"not confirmed","database":"unreachable"}"#.utf8)
        )
        let health = try await makeClient().getHealth()
        XCTAssertFalse(health.isReady)
        XCTAssertEqual(health.database, "unreachable")
    }

    /// `send()` is what every future authenticated route will go through — covered here via a
    /// plain decodable rather than waiting for the first real route to exist, since the
    /// authentication-failure hook is exactly the kind of thing a caller forgets to wire and
    /// silently loses.
    func testSendInvokesAuthFailureCallbackOnlyOn401Or403() async throws {
        final class Capture: @unchecked Sendable {
            var errors: [MVError] = []
        }
        let capture = Capture()
        let client = try makeClient(onAuthenticationFailure: { capture.errors.append($0) })

        MVStubURLProtocol.stub = .init(statusCode: 401, headers: [:], body: Data(#"{"detail":"expired"}"#.utf8))
        await assertThrowsErrorAsync(try await client.send(path: "/api/whatever") as EmptyBody)
        XCTAssertEqual(capture.errors.count, 1)

        MVStubURLProtocol.stub = .init(statusCode: 404, headers: [:], body: Data(#"{"detail":"gone"}"#.utf8))
        await assertThrowsErrorAsync(try await client.send(path: "/api/whatever") as EmptyBody)
        XCTAssertEqual(capture.errors.count, 1, "a 404 is not a credential failure and must not fire the hook")
    }

    /// The redirect itself — `MVRedirectGuard` refuses to follow it, so the 3xx response reaches
    /// `send()` exactly as the server sent it, never a followed 200.
    func testRedirectStatusBecomesProxyRequiresBrowserLogin() async throws {
        MVStubURLProtocol.stub = .init(statusCode: 302, headers: [:], body: Data())
        do {
            _ = try await makeClient().send(path: "/api/whatever") as EmptyBody
            XCTFail("expected proxyRequiresBrowserLogin")
        } catch let error as MVError {
            XCTAssertEqual(error, .proxyRequiresBrowserLogin)
        }
    }

    /// A cookie-only SSO answering 200 with its own login page, no redirect at all.
    func testHtmlBodyOn200BecomesProxyRequiresBrowserLogin() async throws {
        MVStubURLProtocol.stub = .init(
            statusCode: 200, headers: ["Content-Type": "text/html; charset=utf-8"],
            body: Data("<html><body>sign in</body></html>".utf8)
        )
        do {
            _ = try await makeClient().send(path: "/api/whatever") as EmptyBody
            XCTFail("expected proxyRequiresBrowserLogin")
        } catch let error as MVError {
            XCTAssertEqual(error, .proxyRequiresBrowserLogin)
        }
    }
}

private struct EmptyBody: Decodable {}

/// `XCTAssertThrowsError` has no `async` overload, so an `async throws` expression needs its own
/// minimal shim.
private func assertThrowsErrorAsync<T>(
    _ expression: @autoclosure () async throws -> T, _ message: String = "",
    file: StaticString = #filePath, line: UInt = #line
) async {
    do {
        _ = try await expression()
        XCTFail(message.isEmpty ? "expected an error to be thrown" : message, file: file, line: line)
    } catch {
        // Expected.
    }
}
