import Foundation

// URLSession and friends live in FoundationNetworking on Linux, where the free CI runner builds
// this package. On Apple platforms the module does not exist and Foundation already has them.
#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif

/// Builds every request the app sends.
///
/// One place owns the base URL and the bearer header, so every transport — the REST client and
/// the SSE stream alike — applies them the same way instead of each carrying its own copy.
public struct MVRequestFactory: Sendable {

    public enum ConfigurationError: Error, Equatable {
        case emptyBaseURL
        case unsupportedScheme(String?)
        case malformedBaseURL
    }

    private let baseURL: URL
    private let authProvider: @Sendable () -> MVAuthMode

    /// - Parameter authProvider: read at send time rather than captured, so a credential entered
    ///   or changed in settings takes effect on the next request without rebuilding the client.
    public init(
        baseURL rawBaseURL: String,
        authProvider: @escaping @Sendable () -> MVAuthMode
    ) throws {
        let trimmed = rawBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw ConfigurationError.emptyBaseURL }

        guard let url = URL(string: trimmed) else { throw ConfigurationError.malformedBaseURL }
        guard let scheme = url.scheme?.lowercased(), scheme == "https" || scheme == "http" else {
            throw ConfigurationError.unsupportedScheme(url.scheme)
        }

        // A trailing slash would double up against the leading slash every path carries.
        let normalized = trimmed.hasSuffix("/") ? String(trimmed.dropLast()) : trimmed
        guard let normalizedURL = URL(string: normalized) else {
            throw ConfigurationError.malformedBaseURL
        }

        self.baseURL = normalizedURL
        self.authProvider = authProvider
    }

    public func makeRequest(
        path: String,
        method: String = "GET",
        query: [URLQueryItem] = [],
        body: Data? = nil,
        contentType: String? = nil
    ) throws -> URLRequest {
        guard var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) else {
            throw ConfigurationError.malformedBaseURL
        }
        // `percentEncodedPath`, not `appendingPathComponent` — the latter treats its argument as
        // raw, unescaped text and re-encodes anything already percent-encoded in it, which would
        // matter the moment a path segment needs one character escaped (a folder name, a search
        // cursor).
        components.percentEncodedPath = baseURL.path + path
        if !query.isEmpty {
            components.queryItems = query
            // `+` is a legal literal character in a URL query per RFC 3986, so `URLComponents`
            // leaves one alone if a value contains it — but a server commonly parses the query as
            // `application/x-www-form-urlencoded`, where a literal `+` decodes to a space.
            // Escape it explicitly so a value that happens to contain one round-trips instead of
            // silently becoming a space server-side.
            components.percentEncodedQuery = components.percentEncodedQuery?
                .replacingOccurrences(of: "+", with: "%2B")
        }

        guard let url = components.url else { throw ConfigurationError.malformedBaseURL }

        var request = URLRequest(url: url)
        request.httpMethod = method
        request.httpBody = body

        switch authProvider() {
        case .none:
            break
        case .bearer(let token):
            if !token.isEmpty {
                request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            }
        case .basic(let username, let password):
            let raw = Data("\(username):\(password)".utf8).base64EncodedString()
            request.setValue("Basic \(raw)", forHTTPHeaderField: "Authorization")
        }
        if let contentType {
            request.setValue(contentType, forHTTPHeaderField: "Content-Type")
        }
        return request
    }
}
