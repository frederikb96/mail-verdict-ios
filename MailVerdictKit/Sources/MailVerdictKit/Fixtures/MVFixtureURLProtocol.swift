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
    /// Registered with `URLProtocol.registerClass(_:)` rather than handed to a custom
    /// `URLSessionConfiguration`: that reaches `URLSession.shared`, which is what `MVApiClient`
    /// and `MVSseClient` both default to, so nothing that constructs them needs to change to be
    /// intercepted. `canInit` still gates on `MVFixtureLaunch`, so a registered-but-inactive
    /// protocol leaves an ordinary debug run talking to the real network.
    ///
    /// The table below carries only `/api/health`, matching the one real route this app calls.
    /// Extend `routes` alongside a new screen's own fetch call — the one place a fixture response
    /// is wired to the path that requests it.
    public final class MVFixtureURLProtocol: URLProtocol {

        override public class func canInit(with request: URLRequest) -> Bool {
            MVFixtureLaunch.isEnabled()
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

        struct Match {
            let status: Int
            let body: () -> Data
        }

        private struct FixtureRoute: Sendable {
            let method: String
            let path: String
            let body: @Sendable () -> Data
        }

        /// The response for a request the table has no entry for: a well-formed `MVError` body —
        /// `{"detail": ...}` is the one shape every call site already parses — rather than an
        /// empty or wrongly-typed payload a decoder would choke on. Internal, not private, so a
        /// test can assert on it directly without going through a real `URLRequest`.
        static func route(method: String, path: String) -> Match {
            guard let fixture = routes.first(where: { $0.method == method && $0.path == path }) else {
                let detail = "no fixture route for \(method) \(path)"
                return Match(status: 404) { Data("{\"detail\":\"\(detail)\"}".utf8) }
            }
            return Match(status: 200, body: fixture.body)
        }

        private static let routes: [FixtureRoute] = [
            FixtureRoute(method: "GET", path: "/api/health") {
                Data(#"{"status":"ready","postimap_contract":"ok","database":"ok"}"#.utf8)
            }
        ]
    }

#endif
