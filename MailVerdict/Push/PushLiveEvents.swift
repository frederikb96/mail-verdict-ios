import MailVerdictKit

extension PushCoordinator: LiveEventSubscriber {
    /// A dismissal anywhere — the web's bell, another device, this app's own reader — can leave a
    /// banner on this phone for mail already dealt with, and changes the badge.
    func apply(_ invalidations: [MVLiveInvalidation]) {
        guard invalidations.contains(where: { $0 == .alertsChanged || $0 == .resync }) else { return }
        Task { await reconcile() }
    }
}
