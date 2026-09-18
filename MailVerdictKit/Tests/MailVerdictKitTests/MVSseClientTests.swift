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

    /// Several callers asking for the stream at once — a scene phase change, a store reacting to
    /// a disconnect, a retry already in flight — must produce one connection between them, not
    /// one each. This is the property that bounds what reaches the server when something upstream
    /// starts asking repeatedly.
    func testSeveralCallersAskingToConnectAtOnceOpenOneStreamBetweenThem() async {
        MVStubURLProtocol.stub = .init(statusCode: 200, headers: [:], body: Data())
        let factory = try! MVRequestFactory(baseURL: "https://stub.example.com", authProvider: { .none })
        let client = MVSseClient(
            requestFactory: factory,
            callbacks: .init(onRecord: { _ in }, onActivity: {}, onConnected: {}, onDisconnected: {}),
            urlSessionConfiguration: MVStubURLProtocol.makeConfiguration()
        )
        for _ in 0..<8 { client.connect() }
        try? await Task.sleep(nanoseconds: 300_000_000)
        let started = client.attemptsStarted
        client.disconnect()

        XCTAssertEqual(started, 1, "eight callers started \(started) connection attempts")
    }

    /// A link that accepts the connection and drops it again is what a phone on a weak mobile
    /// connection produces, and it is the shape that turned into hundreds of connections a second
    /// against the server. The stub finishes the response the moment it is delivered, which is
    /// exactly that: the client must still space its attempts out rather than spin.
    func testAStreamThatDiesImmediatelyIsRetriedFarApartRatherThanInALoop() async {
        MVStubURLProtocol.stub = .init(statusCode: 200, headers: [:], body: Data())
        let factory = try! MVRequestFactory(baseURL: "https://stub.example.com", authProvider: { .none })
        let client = MVSseClient(
            requestFactory: factory,
            callbacks: .init(onRecord: { _ in }, onActivity: {}, onConnected: {}, onDisconnected: {}),
            urlSessionConfiguration: MVStubURLProtocol.makeConfiguration()
        )
        client.connect()
        try? await Task.sleep(nanoseconds: 3_200_000_000)
        let started = client.attemptsStarted
        client.disconnect()

        let times = MVStubURLProtocol.requestTimes
        XCTAssertGreaterThanOrEqual(times.count, 2, "the client stopped retrying entirely")
        XCTAssertLessThanOrEqual(times.count, 3, "\(times.count) attempts in ~3s is a reconnect storm")
        XCTAssertEqual(times.count, started, "attempts and requests disagree")
        let gaps = zip(times, times.dropFirst()).map { $1.timeIntervalSince($0) }
        for gap in gaps {
            XCTAssertGreaterThan(gap, 1.0, "attempts \(gap)s apart are below the floor")
        }
    }
}

/// The retry policy as pure rules, so the properties that make a connection storm impossible are
/// checked without waiting on wall-clock scheduling.
final class MVSseClientRetryPolicyTests: XCTestCase {

    func testAnAttemptRightAfterAnotherWaitsOutTheRestOfTheFloor() {
        let remaining = MVSseClient.remainingFloorNanos(sinceLastAttempt: 0.25)
        XCTAssertEqual(Double(remaining), 750_000_000, accuracy: 1_000_000)
    }

    func testAnAttemptAfterTheFloorHasPassedWaitsForNothing() {
        XCTAssertEqual(MVSseClient.remainingFloorNanos(sinceLastAttempt: 5), 0)
    }

    func testTheBackoffDoublesAndThenStopsAtItsCap() {
        var backoff = MVSseClient.initialBackoffNanos
        var seen: [UInt64] = []
        for _ in 0..<10 {
            backoff = MVSseClient.nextBackoffNanos(after: backoff)
            seen.append(backoff)
        }
        XCTAssertEqual(seen.first, MVSseClient.initialBackoffNanos * 2)
        XCTAssertEqual(seen.last, MVSseClient.maxBackoffNanos)
        XCTAssertTrue(seen.allSatisfy { $0 <= MVSseClient.maxBackoffNanos })
    }

    func testJitterStaysWithinItsFractionOfTheDelay() {
        let base = MVSseClient.initialBackoffNanos
        let spread = Double(base) * MVSseClient.backoffJitterFraction
        for _ in 0..<200 {
            let delay = Double(MVSseClient.jittered(base))
            XCTAssertGreaterThanOrEqual(delay, Double(base) - spread - 1)
            XCTAssertLessThanOrEqual(delay, Double(base) + spread + 1)
        }
    }

    /// The reason the response status cannot be what resets the backoff: a connection that is
    /// accepted and dropped immediately looks identical to a healthy one at that point.
    func testOnlyAStreamThatHasCarriedTrafficForAWhileCountsAsHealthy() {
        XCTAssertFalse(MVSseClient.streamIsHealthy(openFor: 0))
        XCTAssertFalse(MVSseClient.streamIsHealthy(openFor: MVSseClient.healthyStreamInterval - 0.1))
        XCTAssertTrue(MVSseClient.streamIsHealthy(openFor: MVSseClient.healthyStreamInterval))
    }
}
