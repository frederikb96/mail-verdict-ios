import Foundation

/// How this install authenticates to its backend — a self-hoster's own choice, never a single
/// assumption the app makes for them. `MVRequestFactory` reads whichever mode the caller is
/// currently configured with at send time, the same "read at send time, not construction time"
/// rule the bearer-only predecessor already followed.
public enum MVAuthMode: Sendable, Equatable, Codable {
    /// A LAN, Tailscale or VPN install with no proxy in front of it.
    case none
    case bearer(token: String)
    /// An nginx/Traefik basic-auth proxy in front of the backend.
    case basic(username: String, password: String)
}
