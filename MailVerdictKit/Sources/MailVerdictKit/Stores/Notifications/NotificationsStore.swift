import Foundation
import Observation

/// Mail and System tabs — the Mail tab over `GET /api/alerts`, the System tab merging the
/// non-mail alert kinds with the cross-account `GET /api/notifications`, one call rather than a
/// fan-out across every account. The badge itself is never computed here, or anywhere on the
/// phone — `GET /api/alerts/badge` is the one source, read by whichever screen shows it
/// (Mailboxes' bell).
@Observable
@MainActor
public final class NotificationsStore {
    public private(set) var mailAlerts: [AlertResponse] = []
    public private(set) var systemAlerts: [AlertResponse] = []
    public private(set) var notifications: [NotificationResponse] = []
    public private(set) var isLoading = false
    public private(set) var errorMessage: String?

    private let apiClient: MVApiClient
    private var liveSubscriptionToken: MVSubscriptionToken?

    public init(apiClient: MVApiClient) {
        self.apiClient = apiClient
    }

    // MARK: - Live updates

    public func subscribeToLive(_ hub: LiveEventHub) {
        guard liveSubscriptionToken == nil else { return }
        liveSubscriptionToken = hub.subscribe(self)
    }

    public func unsubscribeFromLive(_ hub: LiveEventHub) {
        guard let token = liveSubscriptionToken else { return }
        hub.unsubscribe(token)
        liveSubscriptionToken = nil
    }

    /// Sequential rather than `async let`-concurrent, deliberately: the two calls are
    /// independent, and awaiting them one at a time means a failure on either still leaves the
    /// other tab showing real data instead of failing the whole screen for both.
    public func load() async {
        isLoading = mailAlerts.isEmpty && systemAlerts.isEmpty && notifications.isEmpty
        errorMessage = nil

        do {
            let alertList = try await apiClient.listAlerts(limit: 200, unseenOnly: true)
            mailAlerts = alertList.filter { NotificationsSupport.isMailAlertKind($0.kind) }
            systemAlerts = alertList.filter { !NotificationsSupport.isMailAlertKind($0.kind) }
        } catch {
            errorMessage = error.mvUserMessage
        }

        do {
            notifications = try await apiClient.listAllNotifications(unacknowledgedOnly: true)
        } catch {
            errorMessage = errorMessage ?? error.mvUserMessage
        }

        isLoading = false
        reportDebugState()
    }

    // MARK: - Mail tab

    public func dismissAlert(_ id: UUID) async {
        try? await apiClient.dismissAlert(id: id)
        mailAlerts.removeAll { $0.id == id }
        systemAlerts.removeAll { $0.id == id }
        reportDebugState()
    }

    public func dismissAllMailAlerts() async {
        try? await apiClient.dismissAllAlerts(kinds: [NotificationsSupport.mailAlertKind])
        mailAlerts = []
        reportDebugState()
    }

    // MARK: - System tab

    /// Every non-mail kind currently represented among the loaded alerts — `dismissAllAlerts`
    /// takes an explicit kind list, so this is what "Dismiss All" on the System tab passes.
    public var systemAlertKinds: [String] {
        var seen: [String] = []
        for alert in systemAlerts where !seen.contains(alert.kind) { seen.append(alert.kind) }
        return seen
    }

    public func acknowledgeNotification(accountId: UUID, notificationId: Int) async {
        try? await apiClient.acknowledgeNotification(accountId: accountId, notificationId: notificationId)
        notifications.removeAll { $0.id == notificationId && $0.accountId == accountId }
        reportDebugState()
    }

    /// Dismiss-all across every account carrying an unacknowledged notification, plus every
    /// System-tab alert kind — there is no cross-account ack-all endpoint, so this is one ack-all
    /// call per account with something to clear, the same the web does.
    public func dismissAllSystem() async {
        let accountIds = Array(Set(notifications.map(\.accountId)))
        await withTaskGroup(of: Void.self) { group in
            for accountId in accountIds {
                group.addTask { [apiClient] in
                    try? await apiClient.acknowledgeAllNotifications(accountId: accountId)
                }
            }
        }
        if !systemAlertKinds.isEmpty {
            try? await apiClient.dismissAllAlerts(kinds: systemAlertKinds)
        }
        notifications = []
        systemAlerts = []
        reportDebugState()
    }

    // MARK: - Opening an alert (Mail tab tap, or a System alert row tap)

    /// Dismisses the alert (if unseen) and resolves where its message is now — the caller (the
    /// screen) pushes the resulting route. Mirrors the web's `openAlert`.
    public func resolveAndDismiss(_ alert: AlertResponse, resolver: MVMessagePlaceResolver) async
        -> MVMessagePlaceResolution?
    {
        if alert.dismissedAt == nil {
            await dismissAlert(alert.id)
        }
        guard let messageId = alert.messageId else { return nil }
        return await resolver.resolve(messageId: messageId)
    }

    private func reportDebugState() {
        #if DEBUG
            NotificationsDebugReporter.shared.report(
                MVNotificationsDebugSnapshot(
                    mailCount: mailAlerts.count, systemAlertCount: systemAlerts.count,
                    notificationCount: notifications.count
                )
            )
        #endif
    }
}

extension NotificationsStore: LiveEventSubscriber {
    /// `alert.new`/`alert.dismissed` and `notification.new` refetch this store — `resync` too,
    /// the same as every other store's live-update handling.
    public func apply(_ invalidations: [MVLiveInvalidation]) {
        let shouldReload = invalidations.contains {
            switch $0 {
            case .resync, .alertsChanged, .notificationsChanged: return true
            default: return false
            }
        }
        guard shouldReload else { return }
        Task { await self.load() }
    }
}
