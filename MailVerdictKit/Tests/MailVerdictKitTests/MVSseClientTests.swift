import XCTest
@testable import MailVerdictKit

/// `shouldReconnectAfterStreamEnded` is what stops a deliberate `disconnect()` from immediately
/// reopening the connection it was just told to close — a regression here means `disconnect()`
/// no longer disconnects.
final class MVSseClientTests: XCTestCase {

    func testDoesNotReconnectWhenCancelled() {
        XCTAssertFalse(MVSseClient.shouldReconnectAfterStreamEnded(cancelled: true, stopped: false))
    }

    func testDoesNotReconnectWhenStopped() {
        XCTAssertFalse(MVSseClient.shouldReconnectAfterStreamEnded(cancelled: false, stopped: true))
    }

    func testReconnectsWhenTheStreamEndedForAnyOtherReason() {
        XCTAssertTrue(MVSseClient.shouldReconnectAfterStreamEnded(cancelled: false, stopped: false))
    }
}

/// Connects a real `MVSseClient` against a stubbed `URLProtocol` and asserts its callback fires
/// with a record decoded from raw bytes — not from a hand-fed line. `MVSseEventAccumulatorTests`
/// and `MVHttpByteStreamTests` prove the pure pieces individually; this proves they are wired
/// together correctly, exercising the exact `connect()` path production code calls — including
/// that the record's `id` becomes the `Last-Event-ID` a reconnect would send.
///
/// Every test method is `async` even though nothing here is otherwise synchronous-only — a
/// `@MainActor XCTestCase` whose methods are all synchronous crashes on Linux at runtime with no
/// compile error, inside generated test discovery.
@MainActor
final class MVSseClientConnectionTests: XCTestCase {

    override func tearDown() {
        MVStubURLProtocol.reset()
        super.tearDown()
    }

    func testConnectDecodesRawStubbedBytesIntoTheRecordCallback() async {
        let raw = "id: a1b2-9\r\nevent: verdict_issued\r\ndata: {\"mail_id\":\"7\"}\r\n\r\n"
        MVStubURLProtocol.stub = .init(statusCode: 200, headers: [:], body: Data(raw.utf8))

        let factory = try! MVRequestFactory(
            baseURL: "https://stub.example.com", authProvider: { .bearer(token: "jwt") })
        let signal = MVStreamConnectionSignal()
        var received: MVSseRecord?

        let callbacks = MVSseClient.Callbacks(
            onRecord: { record in
                received = record
                Task { await signal.fire() }
            },
            onActivity: {},
            onConnected: {},
            onDisconnected: {}
        )

        let client = MVSseClient(
            requestFactory: factory, callbacks: callbacks,
            urlSessionConfiguration: MVStubURLProtocol.makeConfiguration()
        )
        client.connect()
        await signal.wait()
        client.disconnect()

        XCTAssertEqual(received, MVSseRecord(id: "a1b2-9", name: "verdict_issued", data: #"{"mail_id":"7"}"#))
    }

    /// `account_id` must reach the query string exactly when one was configured — a client with
    /// no account scope must not silently send an empty `account_id=` that a server could
    /// misread as "filter to the account named the empty string" rather than "no filter".
    func testAccountScopedClientSendsTheAccountIdQueryParameter() async {
        MVStubURLProtocol.stub = .init(statusCode: 200, headers: [:], body: Data())
        let factory = try! MVRequestFactory(baseURL: "https://stub.example.com", authProvider: { .none })
        let signal = MVStreamConnectionSignal()
        let client = MVSseClient(
            accountId: "acct-123", requestFactory: factory,
            callbacks: .init(
                onRecord: { _ in }, onActivity: {},
                onConnected: { Task { await signal.fire() } }, onDisconnected: {}
            ),
            urlSessionConfiguration: MVStubURLProtocol.makeConfiguration()
        )
        client.connect()
        await signal.wait()
        client.disconnect()

        let url = MVStubURLProtocol.capturedRequest?.url?.absoluteString ?? ""
        XCTAssertTrue(url.contains("account_id=acct-123"), url)
    }
}
