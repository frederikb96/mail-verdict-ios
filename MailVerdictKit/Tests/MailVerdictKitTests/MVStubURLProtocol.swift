import Foundation

// URLSession and friends live in FoundationNetworking on Linux, where the free CI runner builds
// this package. On Apple platforms the module does not exist and Foundation already has them.
#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif

/// A minimal `URLProtocol` stub so `MVApiClient` tests exercise the real request-building and
/// response-decoding path — query items, body, headers, status handling — without a network
/// call. Static state is lock-protected rather than actor-isolated: `URLProtocol` callbacks run
/// on whatever thread `URLSession` schedules them on, outside Swift concurrency's control.
final class MVStubURLProtocol: URLProtocol {
    struct Stub {
        let statusCode: Int
        let headers: [String: String]
        let body: Data
        /// When set, `startLoading()` delivers the body across these `didLoad` calls instead of
        /// one — proving a streaming client reassembles content (and framing) the network
        /// happened to split across chunk boundaries, rather than only ever seeing it whole.
        var bodyChunks: [Data]? = nil
        /// Seconds before the response is delivered, so a test can make one request land after
        /// another.
        var delay: TimeInterval = 0
        /// Fails the request with this transport error instead of answering it.
        var failure: URLError.Code? = nil
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var _stub: Stub?
    nonisolated(unsafe) private static var _stubsByPath: [String: Stub] = [:]
    nonisolated(unsafe) private static var _queue: [Stub] = []
    nonisolated(unsafe) private static var _finishedCount = 0
    nonisolated(unsafe) private static var _capturedRequest: URLRequest?
    nonisolated(unsafe) private static var _capturedRequests: [URLRequest] = []
    nonisolated(unsafe) private static var _requestTimes: [Date] = []

    static var stub: Stub? {
        get { lock.lock(); defer { lock.unlock() }; return _stub }
        set { lock.lock(); defer { lock.unlock() }; _stub = newValue }
    }

    /// How many requests have been answered in full. A test waits for this before starting work
    /// that cancels earlier requests: cancelling one still being answered aborts or hangs
    /// swift-corelibs-foundation.
    static var finishedCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return _finishedCount
    }

    /// Answers taken one per request, in order, before `stubsByPath` and `stub` — for a test of
    /// what a client does with a failure followed by a success.
    static var queue: [Stub] {
        get { lock.lock(); defer { lock.unlock() }; return _queue }
        set { lock.lock(); defer { lock.unlock() }; _queue = newValue }
    }

    /// Per-path answers, consulted before `stub`, for a test whose code asks several routes.
    static var stubsByPath: [String: Stub] {
        get { lock.lock(); defer { lock.unlock() }; return _stubsByPath }
        set { lock.lock(); defer { lock.unlock() }; _stubsByPath = newValue }
    }

    /// Every request that reached the stub, in arrival order.
    static var capturedRequests: [URLRequest] {
        lock.lock()
        defer { lock.unlock() }
        return _capturedRequests
    }

    static var capturedPaths: [String] { capturedRequests.map { $0.url?.path ?? "" } }

    static var capturedRequest: URLRequest? {
        get { lock.lock(); defer { lock.unlock() }; return _capturedRequest }
        set { lock.lock(); defer { lock.unlock() }; _capturedRequest = newValue }
    }

    /// When each request reached the stub, so a test can assert on how often a reconnecting
    /// client opens the stream and how far apart the attempts are.
    static var requestTimes: [Date] {
        lock.lock()
        defer { lock.unlock() }
        return _requestTimes
    }

    static func reset() {
        stub = nil
        capturedRequest = nil
        lock.lock()
        _stubsByPath = [:]
        _queue = []
        _finishedCount = 0
        _capturedRequests = []
        _requestTimes = []
        lock.unlock()
    }

    /// Shared by every stub-backed test, including the delegate-based streaming client — that
    /// builds its own `URLSession` around this configuration rather than reusing `makeSession()`,
    /// since it needs to pass its own delegate.
    static func makeConfiguration() -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MVStubURLProtocol.self]
        return configuration
    }

    static func makeSession() -> URLSession {
        URLSession(configuration: makeConfiguration())
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.capturedRequest = request
        Self.lock.lock()
        Self._requestTimes.append(Date())
        Self._capturedRequests.append(request)
        Self.lock.unlock()

        Self.lock.lock()
        let queued = Self._queue.isEmpty ? nil : Self._queue.removeFirst()
        Self.lock.unlock()
        guard let stub = queued ?? Self.stubsByPath[request.url?.path ?? ""] ?? Self.stub, let url = request.url else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        guard stub.delay > 0 else {
            deliver(stub, for: url)
            return
        }
        nonisolated(unsafe) let protocolInstance = self
        DispatchQueue.global().asyncAfter(deadline: .now() + stub.delay) {
            protocolInstance.deliver(stub, for: url)
        }
    }

    private let stopLock = NSLock()
    nonisolated(unsafe) private var isStopped = false

    private func deliver(_ stub: Stub, for url: URL) {
        // A cancelled task is already gone from the session's registry; answering it afterwards
        // aborts the process inside swift-corelibs-foundation.
        stopLock.lock()
        defer { stopLock.unlock() }
        guard !isStopped else { return }
        if let failure = stub.failure {
            client?.urlProtocol(self, didFailWithError: URLError(failure))
            return
        }
        let response = HTTPURLResponse(
            url: url,
            statusCode: stub.statusCode,
            httpVersion: "HTTP/1.1",
            headerFields: stub.headers
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        if let chunks = stub.bodyChunks {
            for chunk in chunks { client?.urlProtocol(self, didLoad: chunk) }
        } else {
            client?.urlProtocol(self, didLoad: stub.body)
        }
        client?.urlProtocolDidFinishLoading(self)
        Self.lock.lock()
        Self._finishedCount += 1
        Self.lock.unlock()
    }

    override func stopLoading() {
        stopLock.lock()
        isStopped = true
        stopLock.unlock()
    }
}
