import Foundation
import Observation

/// Whether the server can be reached right now, as every screen shows it — the one answer the
/// list and the reader both read, so they never disagree about being offline.
public enum MVReachability: Sendable, Equatable {
    case online
    /// The device has no network path at all.
    case offline
    /// The device has a network path, but the server's live stream has not come back within its
    /// grace period — the server, a VPN or the proxy in front of it is down.
    case serverUnreachable

    /// `stream` is `LiveEventHub.visibleConnectionState`, already past its grace period.
    /// `.disconnected` is a connection that was never started or was closed on sign-out.
    public init(pathAvailable: Bool, stream: MVConnectionState) {
        guard pathAvailable else {
            self = .offline
            return
        }
        switch stream {
        case .connected: self = .online
        case .reconnecting: self = .serverUnreachable
        case .disconnected: self = .offline
        }
    }

    public var isOnline: Bool { self == .online }
}

/// The device's network path as something a view can observe: `MVConnectivity` reports changes
/// through a callback, which SwiftUI cannot see.
@Observable
@MainActor
public final class MVNetworkStatus {
    public private(set) var pathAvailable: Bool

    public init(connectivity: any MVConnectivity) {
        pathAvailable = connectivity.isOnline
        connectivity.observe { [weak self] online in
            self?.pathAvailable = online
        }
    }
}

/// A short line saying the screen is not live, for the capsule a screen shows while offline.
public struct MVOfflineNotice: Sendable, Equatable {
    public let text: String

    /// `savedAt` is when the content on screen was saved, when it came from the offline cache
    /// rather than the server. `nil` when there is nothing worth saying: online and live.
    public static func make(reachability: MVReachability, savedAt: Date?, now: Date = Date()) -> MVOfflineNotice? {
        let saved = savedAt.map { "Saved \(MVDateFormat.relativeAgo($0, now: now))" }
        switch reachability {
        case .offline:
            return MVOfflineNotice(text: ["Offline", saved].compactMap { $0 }.joined(separator: " · "))
        case .serverUnreachable:
            return MVOfflineNotice(text: ["Server unreachable", saved].compactMap { $0 }.joined(separator: " · "))
        case .online:
            return saved.map { MVOfflineNotice(text: "Showing a saved copy · \($0)") }
        }
    }
}
