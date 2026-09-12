import Foundation

// This file mirrors the backend's own response shape by hand — see `GET /api/health` in
// `mail_verdict/server.py` for the one this wraps. A route added, removed or renamed there is
// parity work for whichever piece owns `Models/` from here.

/// `GET /api/health`'s readiness body. `status` is `"ready"`/`"not_ready"`; `postimapContract`
/// and `database` are short diagnostic strings (`"ok"`, `"unreachable"`, `"slow"`, …) rather than
/// enums — the route documents them as informal, and pinning them to a closed set here would
/// make a new one the server adds an unrelated decoding failure instead of a string this client
/// simply has not seen a label for yet.
public struct HealthResponse: Codable, Sendable, Equatable {
    public let status: String
    public let postimapContract: String
    public let database: String
    /// Not sent by every server yet — older deployments simply omit the field, which decodes to
    /// `nil` here rather than failing. "Test Connection" shows it when present.
    public let version: String?

    enum CodingKeys: String, CodingKey {
        case status
        case postimapContract = "postimap_contract"
        case database
        case version
    }

    public init(status: String, postimapContract: String, database: String, version: String? = nil) {
        self.status = status
        self.postimapContract = postimapContract
        self.database = database
        self.version = version
    }

    /// Whether the backend itself reported itself ready — the one field every caller actually
    /// acts on; `postimapContract`/`database` are for a diagnostics screen, not a decision.
    public var isReady: Bool { status == "ready" }
}
