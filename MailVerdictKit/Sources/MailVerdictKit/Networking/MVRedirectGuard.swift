import Foundation

// URLSession and friends live in FoundationNetworking on Linux, where the free CI runner builds
// this package. On Apple platforms the module does not exist and Foundation already has them.
#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif

/// Refuses every HTTP redirect rather than letting `URLSession` follow it silently.
///
/// A cookie-only SSO proxy answers a missing or rejected bearer token with a 302 to its own
/// login page. Followed silently, the app would try to decode that login page's HTML as JSON and
/// report a confusing decoding failure; refused, the 3xx response itself reaches
/// `MVApiClient.checkStatus`, which turns it into `.proxyRequiresBrowserLogin` — a message that
/// actually explains what happened.
final class MVRedirectGuard: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(
        _ session: URLSession, task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }
}

extension URLSession {
    /// The session every real `MVApiClient` should be built with — `.shared` cannot carry a
    /// delegate, so redirect refusal needs a session of its own. Tests pass their own session
    /// (backed by a stub `URLProtocol`) and never see this one.
    public static let mvDefault: URLSession = {
        let configuration = URLSessionConfiguration.default
        #if DEBUG
            MVFixtureURLProtocol.installIfEnabled(in: configuration)
        #endif
        return URLSession(configuration: configuration, delegate: MVRedirectGuard(), delegateQueue: nil)
    }()
}
