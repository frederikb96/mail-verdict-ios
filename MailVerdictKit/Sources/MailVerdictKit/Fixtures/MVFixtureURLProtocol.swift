#if DEBUG

    import Foundation

    // URLSession and friends live in FoundationNetworking on Linux, where the free CI runner
    // builds this package. On Apple platforms the module does not exist and Foundation already
    // has them.
    #if canImport(FoundationNetworking)
        import FoundationNetworking
    #endif

    /// Answers every request from a small in-memory table instead of the network, so a screen can
    /// be screenshotted — or driven into a state a healthy backend will not produce — with no
    /// backend at all.
    ///
    /// `URLProtocol.registerClass(_:)` (called once, in `FixtureBootstrap`) only ever reaches
    /// `URLSession.shared` — a session built with its own delegate or an explicit
    /// `URLSessionConfiguration`, which is every session this app actually builds
    /// (`URLSession.mvDefault`, `MVHttpByteStream`'s SSE session), never picks it up. Every real
    /// session-builder instead calls `installIfEnabled(in:)` on its own configuration before
    /// constructing the session, so this protocol ends up in `protocolClasses` explicitly rather
    /// than relying on that global registration. `canInit` still gates on `MVFixtureLaunch`, so a
    /// protocol class sitting in `protocolClasses` with fixture mode off leaves an ordinary debug
    /// run talking to the real network.
    ///
    /// Routes are registered dynamically (`register`), the same shape `Debug/DebugRouter.swift`
    /// already uses for the debug bridge — a feature slice adds its own fixture routes from its
    /// own store or screen file, the one place that already knows the shape of what it fetches,
    /// rather than editing this shared file. Only `/api/health` is seeded here, since this file's
    /// own directory is where `MVFixtureLaunch`/`MVFixtureURLProtocol` themselves are, not where
    /// any feature's data lives.
    public final class MVFixtureURLProtocol: URLProtocol {

        /// Set by a test that cannot make a real launch argument true; left `nil` in the running
        /// app, where `canInit` reads the real `MVFixtureLaunch.isEnabled()` instead.
        nonisolated(unsafe) private static var isEnabledOverride: Bool?

        override public class func canInit(with request: URLRequest) -> Bool {
            lock.lock()
            let override = isEnabledOverride
            lock.unlock()
            return override ?? MVFixtureLaunch.isEnabled()
        }

        /// The one place every real session-builder goes through — `URLSession.mvDefault`,
        /// `MVHttpByteStream.start`, the authenticated image loader's own session. `enabled`
        /// defaults to the real fixture-mode check; a test passes its own value, since nothing
        /// short of a real launch argument can make `MVFixtureLaunch.isEnabled()` answer true.
        public static func installIfEnabled(
            in configuration: URLSessionConfiguration, enabled: Bool = MVFixtureLaunch.isEnabled()
        ) {
            guard enabled else { return }
            lock.lock()
            isEnabledOverride = true
            lock.unlock()
            configuration.protocolClasses = [Self.self] + (configuration.protocolClasses ?? [])
        }

        override public class func canonicalRequest(for request: URLRequest) -> URLRequest {
            request
        }

        override public func startLoading() {
            let method = request.httpMethod ?? "GET"
            let path = request.url?.path ?? ""
            let match = Self.route(method: method, path: path)

            let response = HTTPURLResponse(
                url: request.url ?? URL(string: "https://fixture.invalid")!,
                statusCode: match.status,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "application/json"]
            )!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: match.body())
            client?.urlProtocolDidFinishLoading(self)
        }

        override public func stopLoading() {}

        // MARK: - Route table

        public struct Match: Sendable {
            public let status: Int
            public let body: @Sendable () -> Data
        }

        private struct FixtureRoute: Sendable {
            let method: String
            let path: String
            let status: Int
            let body: @Sendable () -> Data
        }

        private static let lock = NSLock()
        nonisolated(unsafe) private static var routes: [FixtureRoute] = [
            FixtureRoute(method: "GET", path: "/api/health", status: 200) {
                Data(#"{"status":"ready","postimap_contract":"ok","database":"ok"}"#.utf8)
            }
        ]

        /// Adds one route, or replaces it if the same method and path were already registered —
        /// a later registration winning rather than silently doing nothing matches
        /// `DebugRouter.register`'s own rule, and lets a test override a screen's default fixture
        /// for one case without the two fighting over which wins.
        public static func register(
            method: String, path: String, status: Int = 200, body: @escaping @Sendable () -> Data
        ) {
            lock.lock()
            defer { lock.unlock() }
            routes.removeAll { $0.method == method.uppercased() && $0.path == path }
            routes.append(FixtureRoute(method: method.uppercased(), path: path, status: status, body: body))
        }

        /// Back to just `/api/health` — for a test that registers its own routes and must not
        /// leak them into the next one. Also clears `isEnabledOverride` and the miss log, for the
        /// same reason.
        public static func resetToDefaults() {
            lock.lock()
            defer { lock.unlock() }
            routes = [
                FixtureRoute(method: "GET", path: "/api/health", status: 200) {
                    Data(#"{"status":"ready","postimap_contract":"ok","database":"ok"}"#.utf8)
                }
            ]
            isEnabledOverride = nil
            _misses = []
        }

        /// The response for a request the table has no entry for: a well-formed `MVError` body —
        /// `{"detail": ...}` is the one shape every call site already parses — rather than an
        /// empty or wrongly-typed payload a decoder would choke on. Internal, not private, so a
        /// test can assert on it directly without going through a real `URLRequest`. Every miss
        /// also lands in `misses`, so a silently-broken fixture screen shows up on `/fixtures/misses`
        /// instead of only as a blank or error state someone has to notice by eye.
        static func route(method: String, path: String) -> Match {
            lock.lock()
            let found = routes.first { $0.method == method.uppercased() && $0.path == path }
            if found == nil { _misses.append("\(method.uppercased()) \(path)") }
            lock.unlock()
            guard let fixture = found else {
                let detail = "no fixture route for \(method) \(path)"
                return Match(status: 404) { Data("{\"detail\":\"\(detail)\"}".utf8) }
            }
            return Match(status: fixture.status, body: fixture.body)
        }

        // MARK: - Misses

        nonisolated(unsafe) private static var _misses: [String] = []

        /// Every `"METHOD path"` the table had no entry for, in the order they happened — a
        /// screen that silently fell back to an error state instead of its fixture shows up here
        /// even though its own screenshot still "succeeded" by not crashing.
        public static var misses: [String] {
            lock.lock()
            defer { lock.unlock() }
            return _misses
        }
    }

#endif
