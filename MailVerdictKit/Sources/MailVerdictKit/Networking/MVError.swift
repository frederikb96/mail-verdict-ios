import Foundation

// URLSession and friends live in FoundationNetworking on Linux, where the free CI runner builds
// this package. On Apple platforms the module does not exist and Foundation already has them.
#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif

/// The backend's error contract is a JSON body carrying `detail` — FastAPI's default
/// `HTTPException` shape, which every route in this backend raises through.
public enum MVError: Error, Equatable {
    /// The server answered with a JSON body carrying `detail`.
    case detail(String, statusCode: Int)
    /// The server answered with a non-JSON body; the status line is all there is.
    case http(statusCode: Int, reason: String)
    case transport(String)
    case decoding(String)
    /// A 3xx response, or a `text/html` body, on an `/api` call — a login-proxy page came back
    /// instead of JSON, most commonly a cookie-only SSO redirecting an unauthenticated request to
    /// its own sign-in screen rather than answering with a status an API client can act on.
    case proxyRequiresBrowserLogin

    /// The server refused the credential rather than the request.
    ///
    /// Worth asking of the error rather than of a status code at each call site: every caller
    /// that has to remember to check is a caller that can forget, and forgetting means the app
    /// shows an empty screen instead of asking for a new token.
    public var isAuthenticationFailure: Bool {
        switch self {
        case .detail(_, let statusCode), .http(let statusCode, _):
            return statusCode == 401 || statusCode == 403
        case .transport, .decoding, .proxyRequiresBrowserLogin:
            return false
        }
    }

    /// What the user should see. Always non-empty.
    public var userMessage: String {
        switch self {
        case let .detail(text, _): return text
        case let .http(code, reason): return "HTTP \(code): \(reason)"
        case let .transport(text): return text
        case let .decoding(text): return text
        case .proxyRequiresBrowserLogin:
            return "This server's login proxy wants a browser sign-in and does not accept an "
                + "access token for API requests."
        }
    }
}

private struct ErrorBody: Decodable {
    let detail: String
}

extension MVError {
    /// Build from a response the transport already has in hand.
    public static func from(statusCode: Int, body: Data) -> MVError {
        if let parsed = try? JSONDecoder().decode(ErrorBody.self, from: body),
            !parsed.detail.isEmpty
        {
            return .detail(parsed.detail, statusCode: statusCode)
        }
        return .http(
            statusCode: statusCode,
            reason: HTTPURLResponse.localizedString(forStatusCode: statusCode)
        )
    }
}
