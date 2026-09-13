import Foundation

// URLSession and friends live in FoundationNetworking on Linux, where the free CI runner builds
// this package. On Apple platforms the module does not exist and Foundation already has them.
#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif

/// A short line fit for a screen, plus the original error's own text for an optional disclosure
/// — `ErrorStateView` and any other place an error reaches the screen build their message from
/// this rather than from `String(describing:)`, which prints an `NSError`'s full
/// `Domain=...Code=...UserInfo={...}` dump verbatim.
///
/// `MVError` already carries a `userMessage` fit to show directly; this adds the other family an
/// API call can throw — a `URLError` from the transport itself, never wrapped into `MVError`
/// because it never reaches an HTTP response to wrap (offline, an unreachable host, a timeout, a
/// distrusted certificate, a cancelled task) — and falls back to `localizedDescription` for
/// anything neither.
public struct MVUserFacingError {
    public let message: String
    public let technicalDetail: String

    public init(_ error: Error) {
        switch error {
        case let mvError as MVError:
            message = mvError.userMessage
        case let urlError as URLError:
            message = Self.message(for: urlError)
        default:
            message = (error as NSError).localizedDescription
        }
        technicalDetail = String(describing: error)
    }

    private static func message(for urlError: URLError) -> String {
        switch urlError.code {
        case .notConnectedToInternet, .networkConnectionLost, .dataNotAllowed, .internationalRoamingOff:
            return "No internet connection."
        case .cannotFindHost, .cannotConnectToHost, .dnsLookupFailed:
            return "That address could not be reached."
        case .timedOut:
            return "The connection timed out."
        case .secureConnectionFailed, .serverCertificateUntrusted, .serverCertificateHasBadDate,
            .serverCertificateNotYetValid, .serverCertificateHasUnknownRoot, .clientCertificateRejected,
            .clientCertificateRequired:
            return "The connection's security could not be verified."
        case .userAuthenticationRequired:
            return "This server needs a credential."
        case .cancelled:
            return "Cancelled."
        default:
            return urlError.localizedDescription
        }
    }
}

extension Error {
    /// A short line fit to show on screen — see `MVUserFacingError`.
    public var mvUserMessage: String { MVUserFacingError(self).message }

    /// The original error's own text, for a disclosure next to `mvUserMessage` rather than in
    /// place of it.
    public var mvTechnicalDetail: String { MVUserFacingError(self).technicalDetail }

    /// A request this app cancelled itself because something newer superseded it — never a
    /// failure to show. Structured cancellation surfaces from `URLSession` as `URLError.cancelled`
    /// rather than `CancellationError`, so both count.
    public var mvIsCancellation: Bool {
        if self is CancellationError { return true }
        return (self as? URLError)?.code == .cancelled
    }
}
