import XCTest

@testable import MailVerdictKit

#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif

final class ReadRetryTests: XCTestCase {

    override func setUp() {
        MVStubURLProtocol.reset()
    }

    override func tearDown() {
        MVStubURLProtocol.reset()
        super.tearDown()
    }

    private func makeClient() -> MVApiClient {
        MVApiClient(
            requestFactory: try! MVRequestFactory(baseURL: "https://stub.example.com", authProvider: { .none }),
            urlSession: MVStubURLProtocol.makeSession(),
            readRetry: MVReadRetryPolicy(delays: [0.01, 0.01], readTimeout: 30))
    }

    private func answer(_ status: Int, _ body: Data = Data()) -> MVStubURLProtocol.Stub {
        .init(statusCode: status, headers: ["Content-Type": "application/json"], body: body)
    }

    private func failing(_ code: URLError.Code) -> MVStubURLProtocol.Stub {
        .init(statusCode: 0, headers: [:], body: Data(), failure: code)
    }

    /// A proxy answering for a backend that is restarting, then the backend: the read succeeds
    /// instead of showing an error for a blip.
    func testAReadAnsweredByABadGatewayIsAskedAgain() async throws {
        MVStubURLProtocol.queue = [answer(502), answer(200, Data("[]".utf8))]

        let accounts = try await makeClient().listAccounts()

        XCTAssertEqual(accounts, [])
        XCTAssertEqual(MVStubURLProtocol.capturedPaths, ["/api/accounts", "/api/accounts"])
    }

    /// The commonest hiccup on a phone: the keep-alive connection was already gone when the
    /// request went out.
    func testAReadWhoseConnectionDroppedIsAskedAgain() async throws {
        MVStubURLProtocol.queue = [failing(.networkConnectionLost), answer(200, Data("[]".utf8))]

        let accounts = try await makeClient().listAccounts()

        XCTAssertEqual(accounts, [])
        XCTAssertEqual(MVStubURLProtocol.capturedPaths.count, 2)
    }

    /// A write may have landed before its answer was lost; sending it again is the intent
    /// ledger's decision, never the transport's.
    func testAWriteIsNeverAskedAgain() async {
        MVStubURLProtocol.queue = [answer(502), answer(204)]

        do {
            try await makeClient().triggerSync(accountId: UUID())
            XCTFail("a 502 on a write was swallowed")
        } catch {
            XCTAssertEqual((error as? MVError)?.statusCode, 502)
        }
        XCTAssertEqual(MVStubURLProtocol.capturedPaths.count, 1)
    }

    /// With no network at all the offline copy should answer at once, not after the retries.
    func testNoNetworkIsNotAskedAgain() async {
        MVStubURLProtocol.queue = [failing(.notConnectedToInternet), answer(200, Data("[]".utf8))]

        do {
            _ = try await makeClient().listAccounts()
            XCTFail("expected the offline error")
        } catch {
            XCTAssertTrue(error.mvIsServerUnreachable, "\(error)")
        }
        XCTAssertEqual(MVStubURLProtocol.capturedPaths.count, 1)
    }

    /// A read on a link that went dead without an error gives up after the policy's timeout, not
    /// the session's minute; a write keeps the session's own.
    func testReadsCarryTheShorterTimeoutAndWritesDoNot() async throws {
        MVStubURLProtocol.stub = answer(200, Data("[]".utf8))
        let client = MVApiClient(
            requestFactory: try MVRequestFactory(baseURL: "https://stub.example.com", authProvider: { .none }),
            urlSession: MVStubURLProtocol.makeSession(), readRetry: MVReadRetryPolicy(delays: [], readTimeout: 7))

        _ = try await client.listAccounts()
        MVStubURLProtocol.stub = answer(204)
        try await client.triggerSync(accountId: UUID())

        let timeouts = MVStubURLProtocol.capturedRequests.map(\.timeoutInterval)
        XCTAssertEqual(timeouts.count, 2)
        XCTAssertEqual(timeouts.first, 7)
        XCTAssertNotEqual(timeouts.last, 7)
    }

    /// A gateway that stays down: the retries run out and the caller gets the gateway's answer.
    func testAPersistentBadGatewayGivesUpAfterItsRetries() async {
        MVStubURLProtocol.stub = answer(502)

        do {
            _ = try await makeClient().listAccounts()
            XCTFail("expected the 502")
        } catch {
            XCTAssertEqual((error as? MVError)?.statusCode, 502)
        }
        XCTAssertEqual(MVStubURLProtocol.capturedPaths.count, 3)
    }
}

@MainActor
final class NetworkStatusTests: XCTestCase {

    /// A handover between Wi-Fi and cellular reports a short loss; the screens must not flash
    /// "Offline" for it.
    func testABriefLossNeverReadsAsOffline() async throws {
        let connectivity = TestConnectivity(online: true)
        let status = MVNetworkStatus(connectivity: connectivity, offlineGrace: 0.3)

        connectivity.isOnline = false
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertTrue(status.pathAvailable, "the loss counted before its grace ran out")
        connectivity.isOnline = true
        try await Task.sleep(nanoseconds: 500_000_000)

        XCTAssertTrue(status.pathAvailable, "a loss already over still counted once its grace ran out")
    }

    /// A loss that lasts reads as offline, and the path coming back counts at once.
    func testALastingLossReadsAsOfflineAndARecoveryCountsAtOnce() async {
        let connectivity = TestConnectivity(online: true)
        let status = MVNetworkStatus(connectivity: connectivity, offlineGrace: 0.05)

        connectivity.isOnline = false
        await waitUntil { !status.pathAvailable }
        connectivity.isOnline = true

        XCTAssertTrue(status.pathAvailable)
    }
}

@MainActor
final class SseRetryNowTests: XCTestCase {

    override func tearDown() {
        MVHoldOpenStubProtocol.reset()
        super.tearDown()
    }

    /// After an outage the reconnect may be waiting out a long backoff; the network coming back
    /// starts it now. The second backoff here is three to five seconds, so a live stream within
    /// a second and a half can only come from `retryNow()`.
    func testANetworkReturnSkipsTheBackoff() async throws {
        MVHoldOpenStubProtocol.dieImmediately = true
        let factory = try MVRequestFactory(baseURL: "https://stub.example.com", authProvider: { .none })
        let client = MVSseClient(
            requestFactory: factory,
            callbacks: .init(onRecord: { _ in }, onActivity: {}, onConnected: {}, onDisconnected: {}),
            urlSessionConfiguration: MVHoldOpenStubProtocol.makeConfiguration())
        client.connect()
        await waitUntil({ MVHoldOpenStubProtocol.starts == 2 }, timeout: 5)
        try await Task.sleep(nanoseconds: 100_000_000)
        MVHoldOpenStubProtocol.dieImmediately = false

        client.retryNow()

        await waitUntil({ MVHoldOpenStubProtocol.live == 1 }, timeout: 1.5)
        client.disconnect()
    }
}
