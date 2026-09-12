import Foundation

// This file mirrors the backend's own response shapes by hand, the same way pai-ios mirrors
// pai-cloud's web/src/api/types.ts — see `GET /api/health` in `mail_verdict/server.py` for the
// one this wraps. A dedicated route and shape added, removed or renamed there is parity work for
// whichever block owns `Models/` from here.

/// `GET /api/health`'s readiness body. `status` is `"ready"`/`"not_ready"`; `postimapContract`
/// and `database` are short diagnostic strings (`"ok"`, `"unreachable"`, `"slow"`, …) rather than
/// enums — the route documents them as informal, and pinning them to a closed set here would
/// make a new one the server adds an unrelated decoding failure instead of a string this client
/// simply has not seen a label for yet.
public struct HealthResponse: Codable, Sendable, Equatable {
    public let status: String
    public let postimapContract: String
    public let database: String

    enum CodingKeys: String, CodingKey {
        case status
        case postimapContract = "postimap_contract"
        case database
    }

    public init(status: String, postimapContract: String, database: String) {
        self.status = status
        self.postimapContract = postimapContract
        self.database = database
    }

    /// Whether the backend itself reported itself ready — the one field every caller actually
    /// acts on; `postimapContract`/`database` are for a diagnostics screen, not a decision.
    public var isReady: Bool { status == "ready" }
}
