import Foundation

// URLSession and friends live in FoundationNetworking on Linux, where the free CI runner builds
// this package. On Apple platforms the module does not exist and Foundation already has them.
#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif

/// How `MVApiClient` asks again when a read (`GET`) fails for a reason that passes in a moment —
/// a phone switching networks, a keep-alive connection the server already closed, a proxy
/// answering for a backend that is restarting. Only reads: they change nothing on the server, so
/// asking twice is harmless. Writes go through the intent ledger, which retries with its own
/// knowledge of whether an attempt may have landed.
public struct MVReadRetryPolicy: Sendable {
    /// One more attempt per entry, after waiting that long.
    public var delays: [TimeInterval]
    /// How long a read waits without hearing from the server before it gives up, unless the
    /// caller sets its own. Shorter than the session's minute, so a dead link turns into the
    /// offline fallback rather than a screen loading for a minute.
    public var readTimeout: TimeInterval

    public init(delays: [TimeInterval] = [0.25, 1], readTimeout: TimeInterval = 30) {
        self.delays = delays
        self.readTimeout = readTimeout
    }

    /// Not asked again: no network at all (the offline copy should answer at once), a timeout
    /// (it already waited `readTimeout`), and a 503 (the server saying on purpose it cannot serve
    /// this; search reads it as "semantic search unavailable").
    static func isTransient(_ error: Error) -> Bool {
        guard let urlError = error as? URLError else { return false }
        switch urlError.code {
        case .networkConnectionLost, .cannotConnectToHost, .cannotFindHost, .dnsLookupFailed: return true
        default: return false
        }
    }

    static func isTransient(statusCode: Int) -> Bool {
        statusCode == 502 || statusCode == 504
    }
}
