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
        let (data, response) = try await rawSend(
            path: path, method: method, query: query, body: body, contentType: contentType
        )
        try checkStatus(response: response, data: data)
        do {
            return try JSONDecoder.mvDefault.decode(T.self, from: data)
        } catch {
            throw MVError.decoding("\(error)")
        }
    }

    /// For a `204 No Content` route, or any route whose body this caller genuinely does not need
    /// — `send()` would otherwise fail to decode an empty body into a type that expects one.
    func sendNoContent(
        path: String,
        method: String,
        query: [URLQueryItem] = [],
        body: Data? = nil,
        contentType: String? = "application/json"
    ) async throws {
        let (data, response) = try await rawSend(
            path: path, method: method, query: query, body: body, contentType: contentType
        )
        try checkStatus(response: response, data: data)
    }

    /// For a route that streams bytes rather than JSON — attachment, raw `.eml`, contact photo.
    func sendRaw(
        path: String,
        method: String = "GET",
        query: [URLQueryItem] = []
    ) async throws -> (data: Data, contentType: String?, suggestedFilename: String?) {
        let (data, response) = try await rawSend(path: path, method: method, query: query, body: nil, contentType: nil)
        try checkStatus(response: response, data: data)
        let http = response as? HTTPURLResponse
        return (
            data, http?.value(forHTTPHeaderField: "Content-Type"),
            Self.filename(fromContentDisposition: http?.value(forHTTPHeaderField: "Content-Disposition"))
        )
    }

    /// `HTTPURLResponse.suggestedFilename` is an Apple-only convenience swift-corelibs-foundation
    /// does not implement, so the Linux-built package parses the header itself — `filename=` or
    /// the RFC 5987 `filename*=UTF-8''…` form `content_disposition()` (`mail_verdict/utils.py`)
    /// always sends.
    static func filename(fromContentDisposition header: String?) -> String? {
        guard let header else { return nil }
        for part in header.components(separatedBy: ";") {
            let trimmed = part.trimmingCharacters(in: .whitespaces)
            if trimmed.lowercased().hasPrefix("filename*=") {
                let value = String(trimmed.dropFirst("filename*=".count))
                if let tick = value.range(of: "''") {
                    let encoded = String(value[tick.upperBound...])
                    return encoded.removingPercentEncoding ?? encoded
                }
            }
            if trimmed.lowercased().hasPrefix("filename=") {
                var value = String(trimmed.dropFirst("filename=".count))
                if value.hasPrefix("\""), value.hasSuffix("\""), value.count >= 2 {
                    value = String(value.dropFirst().dropLast())
                }
                return value
            }
        }
        return nil
    }

    /// `POST /api/outbox`'s multipart form — `data` is the JSON payload, `attachments` the files,
    /// aligned 1:1 with `contentIds` (`nil` for an ordinary attachment, the `cid:` value for a
    /// pasted inline image).
    func sendMultipart<T: Decodable>(
        path: String,
        jsonPart: Data,
        attachments: [MVOutboxAttachmentUpload]
    ) async throws -> T {
        let boundary = "MVBoundary-\(UUID().uuidString)"
        var body = Data()

        func appendField(name: String, data: Data, filename: String? = nil, contentType: String? = nil) {
            body.append(Data("--\(boundary)\r\n".utf8))
            var disposition = "Content-Disposition: form-data; name=\"\(name)\""
            if let filename { disposition += "; filename=\"\(filename)\"" }
            body.append(Data("\(disposition)\r\n".utf8))
            if let contentType {
                body.append(Data("Content-Type: \(contentType)\r\n".utf8))
            }
            body.append(Data("\r\n".utf8))
            body.append(data)
            body.append(Data("\r\n".utf8))
        }

        appendField(name: "data", data: jsonPart)
        for attachment in attachments {
            appendField(
                name: "attachments", data: attachment.data, filename: attachment.filename,
                contentType: attachment.contentType ?? "application/octet-stream"
            )
        }
        body.append(Data("--\(boundary)--\r\n".utf8))

        let (data, response) = try await rawSend(
            path: path, method: "POST", query: [], body: body,
            contentType: "multipart/form-data; boundary=\(boundary)"
        )
        try checkStatus(response: response, data: data)
        do {
            return try JSONDecoder.mvDefault.decode(T.self, from: data)
        } catch {
            throw MVError.decoding("\(error)")
        }
    }

    func rawSend(
        path: String, method: String, query: [URLQueryItem], body: Data?, contentType: String?
    ) async throws -> (Data, URLResponse) {
        let request = try requestFactory.makeRequest(
            path: path, method: method, query: query, body: body, contentType: contentType
        )
        return try await urlSession.data(for: request)
    }

    static func encodeBody<T: Encodable>(_ value: T) throws -> Data {
        try JSONEncoder.mvDefault.encode(value)
    }

    func checkStatus(response: URLResponse, data: Data) throws {
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
            return try JSONDecoder.mvDefault.decode(HealthResponse.self, from: data)
        } catch {
            throw MVError.decoding("\(error)")
        }
    }
}

/// One file a multipart `POST /api/outbox` upload carries — a picked file or a pasted inline
/// image, aligned 1:1 with `OutboxCreateRequest.inlineAttachmentContentIds`.
public struct MVOutboxAttachmentUpload: Sendable, Equatable {
    public let filename: String
    public let contentType: String?
    public let data: Data

    public init(filename: String, contentType: String?, data: Data) {
        self.filename = filename
        self.contentType = contentType
        self.data = data
    }
}
