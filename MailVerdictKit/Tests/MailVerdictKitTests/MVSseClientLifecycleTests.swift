import XCTest

@testable import MailVerdictKit

#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif
import Foundation

/// A stub that accepts the request and then holds it open, so a test can count how many streams
/// are live at the same instant rather than only how many were started.
final class MVHoldOpenStubProtocol: URLProtocol, @unchecked Sendable {

    private static let lock = NSLock()
    nonisolated(unsafe) private static var _live = 0
    nonisolated(unsafe) private static var _peak = 0
    nonisolated(unsafe) private static var _starts = 0
    nonisolated(unsafe) private static var _dieImmediately = false
    /// Bumped by `reset()`. A straggler from an earlier test whose `stopLoading` lands after the
    /// counters were cleared must not decrement this test's own count below zero — which reads
    /// exactly like the client having failed to open a stream at all.
    nonisolated(unsafe) private static var _epoch = 0

    static var live: Int { lock.lock(); defer { lock.unlock() }; return _live }
    static var peak: Int { lock.lock(); defer { lock.unlock() }; return _peak }
    static var starts: Int { lock.lock(); defer { lock.unlock() }; return _starts }

    static var dieImmediately: Bool {
        get { lock.lock(); defer { lock.unlock() }; return _dieImmediately }
        set { lock.lock(); defer { lock.unlock() }; _dieImmediately = newValue }
    }

    static func reset() {
        lock.lock()
        _epoch += 1
        _live = 0
        _peak = 0
        _starts = 0
        _dieImmediately = false
        lock.unlock()
    }

    static func makeConfiguration() -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MVHoldOpenStubProtocol.self]
        return configuration
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    private var stopped = false
    private var epoch = -1
    private let instanceLock = NSLock()

    private final class WeakBox: @unchecked Sendable {
        weak var value: MVHoldOpenStubProtocol?
        init(_ value: MVHoldOpenStubProtocol) { self.value = value }
    }

    override func startLoading() {
        Self.lock.lock()
        let die = Self._dieImmediately
        epoch = Self._epoch
        Self._starts += 1
        Self._live += 1
        Self._peak = max(Self._peak, Self._live)
        Self.lock.unlock()

        guard let url = request.url else { return }
        let response = HTTPURLResponse(
            url: url, statusCode: 200, httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "text/event-stream"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(": keepalive\n\n".utf8))

        if die {
            markClosed()
            client?.urlProtocolDidFinishLoading(self)
            return
        }
        heartbeat()
    }

    private func heartbeat() {
        let box = WeakBox(self)
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.2) {
            guard let me = box.value else { return }
            me.instanceLock.lock()
            let alive = !me.stopped
            me.instanceLock.unlock()
            guard alive else { return }
            me.client?.urlProtocol(me, didLoad: Data(": keepalive\n\n".utf8))
            me.heartbeat()
        }
    }

    private func markClosed() {
        instanceLock.lock()
        let alreadyStopped = stopped
        stopped = true
        instanceLock.unlock()
        guard !alreadyStopped else { return }
        Self.lock.lock()
        if epoch == Self._epoch { Self._live -= 1 }
        Self.lock.unlock()
    }

    override func stopLoading() {
        markClosed()
    }
}

/// Adversarial properties of `MVSseClient`'s scheduling: what the interleavings a phone actually
/// produces (scene phase flapping, a store asking to connect, a link that accepts and drops) can
/// be driven to.
@MainActor
final class MVSseClientLifecycleTests: XCTestCase {

    override func tearDown() {
        MVHoldOpenStubProtocol.reset()
        super.tearDown()
    }

    private func makeClient(onConnected: @escaping @MainActor @Sendable () -> Void = {}) -> MVSseClient {
        let factory = try! MVRequestFactory(baseURL: "https://stub.example.com", authProvider: { .none })
        return MVSseClient(
            requestFactory: factory,
            callbacks: .init(
                onRecord: { _ in }, onActivity: {}, onConnected: onConnected, onDisconnected: {}),
            urlSessionConfiguration: MVHoldOpenStubProtocol.makeConfiguration()
        )
    }

    /// Control for the instrument itself: one client, one connection, the counter reads one.
    func testTheConcurrencyInstrumentReadsOneForOneClient() async {
        let client = makeClient()
        client.connect()
        try? await Task.sleep(nanoseconds: 700_000_000)
        let peak = MVHoldOpenStubProtocol.peak
        client.disconnect()
        try? await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertEqual(peak, 1, "instrument saw \(peak) live streams for a single connect")
        XCTAssertEqual(MVHoldOpenStubProtocol.live, 0, "disconnect left a stream open")
    }

    /// Scene phase flapping, a store reacting to a disconnect and a retry already in flight, all
    /// interleaved at random. Two properties have to survive it: never two live streams, and a
    /// bounded attempt rate.
    func testFuzzedLifecycleNeverProducesTwoLiveStreamsOrABurst() async {
        let client = makeClient()
        client.connect()

        let deadline = Date().addingTimeInterval(8)
        var operations = 0
        while Date() < deadline {
            switch Int.random(in: 0..<4) {
            case 0: client.connect()
            case 1: client.pause()
            case 2: client.resume()
            default: client.pause(); client.resume()
            }
            operations += 1
            try? await Task.sleep(nanoseconds: UInt64.random(in: 1_000_000...60_000_000))
        }
        client.connect()
        client.resume()
        try? await Task.sleep(nanoseconds: 2_000_000_000)

        let peak = MVHoldOpenStubProtocol.peak
        let starts = MVHoldOpenStubProtocol.starts
        let live = MVHoldOpenStubProtocol.live
        client.disconnect()

        XCTAssertEqual(peak, 1, "\(operations) lifecycle operations produced \(peak) simultaneous streams")
        XCTAssertLessThanOrEqual(starts, 12, "\(starts) attempts in ~10s is a burst")
        XCTAssertEqual(live, 1, "after settling, the client holds \(live) streams — 1 expected")
    }

    /// The failure that is worse than the storm: after being pushed around, the client must still
    /// be connected (or connecting), never silently wedged with nothing in flight.
    func testTheClientStillHoldsAStreamAfterBeingFlappedHard() async {
        let client = makeClient()
        client.connect()
        try? await Task.sleep(nanoseconds: 1_500_000_000)

        for _ in 0..<200 {
            client.pause()
            client.resume()
        }
        for _ in 0..<200 {
            client.connect()
        }
        try? await Task.sleep(nanoseconds: 3_000_000_000)

        let live = MVHoldOpenStubProtocol.live
        let starts = MVHoldOpenStubProtocol.starts
        client.disconnect()

        XCTAssertEqual(live, 1, "after 400 lifecycle calls the client holds \(live) live streams")
        XCTAssertLessThanOrEqual(starts, 6, "\(starts) attempts — the floor did not hold")
    }

    /// A link that accepts and drops, driven for long enough to watch the backoff actually grow:
    /// the attempt count must stay far below a per-second rate.
    func testAnAcceptAndDropLinkBacksOffRatherThanSpinning() async {
        MVHoldOpenStubProtocol.dieImmediately = true
        let client = makeClient()
        client.connect()
        try? await Task.sleep(nanoseconds: 9_000_000_000)
        let starts = MVHoldOpenStubProtocol.starts
        client.disconnect()

        XCTAssertGreaterThanOrEqual(starts, 2, "the client stopped retrying entirely")
        XCTAssertLessThanOrEqual(starts, 5, "\(starts) attempts in 9s on an accept-and-drop link")
    }

    /// `pause()` arriving while a retry is already scheduled, then `resume()` — the pair a scene
    /// phase change produces — must still land on exactly one stream.
    func testPauseDuringAScheduledRetryStillRecovers() async {
        MVHoldOpenStubProtocol.dieImmediately = true
        let client = makeClient()
        client.connect()
        try? await Task.sleep(nanoseconds: 500_000_000)
        // A retry is scheduled behind the backoff by now.
        client.pause()
        try? await Task.sleep(nanoseconds: 200_000_000)
        MVHoldOpenStubProtocol.dieImmediately = false
        client.resume()
        try? await Task.sleep(nanoseconds: 3_000_000_000)

        let live = MVHoldOpenStubProtocol.live
        client.disconnect()
        XCTAssertEqual(live, 1, "resume after a paused retry left \(live) live streams")
    }

    /// `PushCoordinator.makeBackgroundEnvironment()` builds an `AppEnvironment` (which connects)
    /// and closes its hub in the very next statement. Nothing may reach the server at all.
    func testConnectClosedInTheSameTurnOpensNoSocketAtAll() async {
        let client = makeClient()
        client.connect()
        client.disconnect()
        try? await Task.sleep(nanoseconds: 1_500_000_000)
        XCTAssertEqual(
            MVHoldOpenStubProtocol.starts, 0,
            "a connect closed in the same turn still opened \(MVHoldOpenStubProtocol.starts) request(s)")
        XCTAssertEqual(
            MVHoldOpenStubProtocol.live, 0,
            "\(MVHoldOpenStubProtocol.live) socket(s) left open by a connect that was closed at once")
    }

    /// `disconnect()` is terminal: a client that has been disconnected can never be reconnected,
    /// whatever calls `connect()`. Asserted so the cost of reusing one is visible.
    func testDisconnectIsTerminalAndConnectCannotRevive() async {
        let client = makeClient()
        client.connect()
        try? await Task.sleep(nanoseconds: 600_000_000)
        client.disconnect()
        try? await Task.sleep(nanoseconds: 300_000_000)
        let afterDisconnect = MVHoldOpenStubProtocol.starts
        client.connect()
        client.resume()
        try? await Task.sleep(nanoseconds: 1_500_000_000)
        XCTAssertEqual(
            MVHoldOpenStubProtocol.starts, afterDisconnect,
            "connect() after disconnect() opened a stream — the client is revivable after all")
        XCTAssertEqual(MVHoldOpenStubProtocol.live, 0)
    }

    /// The task running a stream holds the client, so a client nobody references any more is not
    /// collected — it keeps a connection on the server for the rest of the process, and there is
    /// no reference left to tell it to stop. A named owner going away is what ends it.
    func testAClientWhoseOwnerIsGoneClosesTheStreamItIsStillHolding() async {
        let client = makeClient()
        var owner: NSObject? = NSObject()
        client.setOwner(owner!)
        client.connect()
        try? await Task.sleep(nanoseconds: 700_000_000)
        XCTAssertEqual(MVHoldOpenStubProtocol.live, 1, "the stream never came up, so the test proves nothing")

        owner = nil
        try? await Task.sleep(nanoseconds: 1_500_000_000)

        let live = MVHoldOpenStubProtocol.live
        client.disconnect()
        XCTAssertEqual(live, 0, "an abandoned client held \(live) streams open")
    }

    /// The same client against a link that accepts and drops: an abandoned one must stop asking,
    /// not go on reconnecting forever. Several of these together are what a connection storm is
    /// made of.
    func testAnAbandonedClientStopsReconnecting() async {
        MVHoldOpenStubProtocol.dieImmediately = true
        let client = makeClient()
        var owner: NSObject? = NSObject()
        client.setOwner(owner!)
        client.connect()
        try? await Task.sleep(nanoseconds: 2_500_000_000)
        XCTAssertGreaterThan(
            MVHoldOpenStubProtocol.starts, 1, "the client was not retrying yet, so the test proves nothing")

        owner = nil
        let atAbandonment = MVHoldOpenStubProtocol.starts
        try? await Task.sleep(nanoseconds: 4_000_000_000)

        let after = MVHoldOpenStubProtocol.starts
        client.disconnect()
        XCTAssertEqual(
            after, atAbandonment,
            "an abandoned client opened \(after - atAbandonment) more streams after its owner was gone")
    }
}
