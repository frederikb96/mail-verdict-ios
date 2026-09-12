import Foundation
import MailVerdictKit
import PushEnvelope

/// The app's own clearing pass: which delivered notifications to withdraw because their alert was
/// read or dismissed elsewhere, and the badge to show. Runs on activation and on a background
/// read-sync wake; the extension's piggybacked `resolved` ids are the other layer.
public struct PushReconciler: Sendable {
    /// The server's cap on one `POST /api/alerts/lookup`.
    static let lookupLimit = 200

    public struct Outcome: Sendable, Equatable {
        public let identifiersToRemove: [String]
        /// `nil` when the server could not be asked — leave the badge as it is rather than guess.
        public let badge: Int?
    }

    private let backend: any PushBackend

    public init(backend: any PushBackend) {
        self.backend = backend
    }

    public func reconcile(delivered: [DeliveredNotification], subscriptionId: UUID?) async -> Outcome {
        let ids = Array(Set(delivered.compactMap(\.alertId)))
        var active = Set<UUID>()
        var answered = true
        var start = 0
        while start < ids.count {
            let chunk = Array(ids[start..<min(start + Self.lookupLimit, ids.count)])
            guard let rows = try? await backend.lookupAlerts(ids: chunk) else {
                answered = false
                break
            }
            active.formUnion(rows.filter { $0.dismissedAt == nil }.map(\.id))
            start += Self.lookupLimit
        }
        // An unanswered lookup says nothing about which alerts are gone; withdrawing on it would
        // clear every banner whenever the server is unreachable.
        let remove =
            answered ? PushClearing.identifiersToRemove(from: delivered, isStale: { !active.contains($0) }) : []

        var badge: Int?
        if let subscriptionId {
            badge = try? await backend.badge(subscriptionId: subscriptionId)
        }
        return Outcome(identifiersToRemove: remove, badge: badge)
    }
}
