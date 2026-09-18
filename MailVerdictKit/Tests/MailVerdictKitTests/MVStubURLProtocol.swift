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
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var _stub: Stub?
    nonisolated(unsafe) private static var _capturedRequest: URLRequest?
    nonisolated(unsafe) private static var _requestTimes: [Date] = []

    static var stub: Stub? {
        get { lock.lock(); defer { lock.unlock() }; return _stub }
        set { lock.lock(); defer { lock.unlock() }; _stub = newValue }
    }

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
        Self.lock.unlock()

        guard let stub = Self.stub, let url = request.url else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
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
    }

    override func stopLoading() {}
}
