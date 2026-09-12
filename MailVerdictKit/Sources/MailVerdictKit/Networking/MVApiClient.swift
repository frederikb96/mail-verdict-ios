import Foundation

// URLSession and friends live in FoundationNetworking on Linux, where the free CI runner builds
// this package. On Apple platforms the module does not exist and Foundation already has them.
#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif

/// The app's one REST client. Every route the app calls goes through `send(path:...)`, so status
/// handling, decoding and the authentication-failure hook live in exactly one place.
///
/// A plain `Sendable` struct: no mutable state, so it needs no actor isolation and is safe to call
/// from anywhere, including inside a streaming client's own request construction.
public struct MVApiClient: Sendable {
    private let requestFactory: MVRequestFactory
    private let urlSession: URLSession
    private let onAuthenticationFailure: (@Sendable (MVError) -> Void)?

    /// `onAuthenticationFailure` is called whenever the server refuses the credential, before the
    /// error is thrown to the caller.
    ///
    /// It exists because the alternative does not work: a first-load path is full of calls whose
    /// failure is genuinely not worth surfacing, so they discard the error — and an expired token
    /// then reads as an app with nothing in it and no way back. Noticing here means no caller has
    /// to remember, and a caller that swallows its error still cannot swallow this.
    public init(
        requestFactory: MVRequestFactory,
        urlSession: URLSession = .mvDefault,
        onAuthenticationFailure: (@Sendable (MVError) -> Void)? = nil
    ) {
        self.requestFactory = requestFactory
        self.urlSession = urlSession
        self.onAuthenticationFailure = onAuthenticationFailure
    }

    // MARK: Core request helper

    func send<T: Decodable>(
        path: String,
        method: String = "GET",
        query: [URLQueryItem] = [],
        body: Data? = nil,
        contentType: String? = "application/json"
    ) async throws -> T {
        let request = try requestFactory.makeRequest(
            path: path, method: method, query: query, body: body, contentType: contentType
        )
        let (data, response) = try await urlSession.data(for: request)
        try checkStatus(response: response, data: data)
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw MVError.decoding("\(error)")
        }
    }

    private func checkStatus(response: URLResponse, data: Data) throws {
        guard let http = response as? HTTPURLResponse else {
            throw MVError.transport("Response was not HTTP")
        }
        // The session this client is built with (see `URLSession.mvDefault`) refuses every
        // redirect, so a 3xx reaching here is the redirect itself, never a followed one — a
        // cookie-only SSO's own login page, most commonly.
        if (300..<400).contains(http.statusCode) {
            throw MVError.proxyRequiresBrowserLogin
        }
        guard (200..<300).contains(http.statusCode) else {
            let error = MVError.from(statusCode: http.statusCode, body: data)
            if error.isAuthenticationFailure { onAuthenticationFailure?(error) }
            throw error
        }
        // A 200 whose body is HTML rather than JSON is the same login-proxy case without a
        // redirect — some SSO fronts answer an unauthenticated /api call with their sign-in page
        // directly, status 200 included.
        if Self.isHTMLContentType(response: http) {
            throw MVError.proxyRequiresBrowserLogin
        }
    }

    private static func isHTMLContentType(response: HTTPURLResponse) -> Bool {
        let contentType = response.value(forHTTPHeaderField: "Content-Type") ?? ""
        return contentType.lowercased().contains("text/html")
    }

    // MARK: Health

    /// `GET /api/health` — readiness, not liveness. The backend answers the same JSON shape
    /// whether it is ready (200) or not (503), and the 503 case is the more informative one for
    /// the connection screen ("reachable but not ready" versus "not reachable at all") — so this
    /// bypasses `send()`'s status check and decodes the body regardless of status code, rather
    /// than turning a perfectly legible "not ready yet" body into a thrown `.http(503, ...)` with
    /// no detail in it.
    public func getHealth() async throws -> HealthResponse {
        let request = try requestFactory.makeRequest(path: "/api/health")
        let (data, response) = try await urlSession.data(for: request)
        guard response is HTTPURLResponse else {
            throw MVError.transport("Response was not HTTP")
        }
        do {
            return try JSONDecoder().decode(HealthResponse.self, from: data)
        } catch {
            throw MVError.decoding("\(error)")
        }
    }
}
