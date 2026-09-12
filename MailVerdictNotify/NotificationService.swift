import Foundation
import PushEnvelope
import UserNotifications

/// Opens the sealed envelope a push carries and rewrites the relay's generic banner into the real
/// one — sender, subject, badge, thread — without anything leaving the phone. The relay and APNs
/// only ever see ciphertext.
///
/// Links `PushEnvelope` alone: an extension runs under a small memory budget, and the rest of the
/// app's package would count against it.
final class NotificationService: UNNotificationServiceExtension {
    private var contentHandler: ((UNNotificationContent) -> Void)?
    private var bestAttemptContent: UNMutableNotificationContent?

    override func didReceive(
        _ request: UNNotificationRequest, withContentHandler contentHandler: @escaping (UNNotificationContent) -> Void
    ) {
        self.contentHandler = contentHandler
        let content = (request.content.mutableCopy() as? UNMutableNotificationContent) ?? UNMutableNotificationContent()
        bestAttemptContent = content

        // No key (turned off, or never registered on this server), a blob that does not
        // authenticate, an unknown version: all of them deliver the relay's generic banner as it
        // came, rather than nothing.
        guard let blob = PushEnvelope.blob(fromUserInfo: request.content.userInfo), let payload = Self.open(blob)
        else {
            deliver(content)
            return
        }

        let banner = PushBanner(payload: payload)
        content.title = banner.title
        content.body = banner.body
        content.badge = NSNumber(value: banner.badge)
        if let threadIdentifier = banner.threadIdentifier { content.threadIdentifier = threadIdentifier }
        if let categoryIdentifier = banner.categoryIdentifier { content.categoryIdentifier = categoryIdentifier }
        var userInfo = content.userInfo
        for (key, value) in banner.userInfo { userInfo[key] = value }
        content.userInfo = userInfo

        Self.withdraw(resolved: Set(payload.resolved))
        deliver(content)
    }

    override func serviceExtensionTimeWillExpire() {
        if let bestAttemptContent { deliver(bestAttemptContent) }
    }

    private func deliver(_ content: UNNotificationContent) {
        contentHandler?(content)
        contentHandler = nil
    }

    /// Tries every server's installation this phone holds; the one the blob authenticates under is
    /// the server it came from. There is normally exactly one.
    private static func open(_ blob: String) -> PushPayload? {
        guard let installations = try? PushKeychain.loadAll() else { return nil }
        for installation in installations {
            if let payload = try? PushEnvelope.openPayload(
                blob: blob, key: installation.contentKey, installationId: installation.installationId)
            {
                return payload
            }
        }
        return nil
    }

    /// Removes banners for alerts dismissed elsewhere, before the new one is handed back: once
    /// the content handler runs, the extension may be torn down at any moment. Waits a bounded
    /// time for the delivered list, which arrives on another queue, so a slow answer only means
    /// the next push or the app's own pass does the clearing instead.
    private static func withdraw(resolved: Set<UUID>) {
        guard !resolved.isEmpty else { return }
        let done = DispatchSemaphore(value: 0)
        UNUserNotificationCenter.current().getDeliveredNotifications { notifications in
            let delivered = notifications.map {
                DeliveredNotification(identifier: $0.request.identifier, userInfo: $0.request.content.userInfo)
            }
            let stale = PushClearing.identifiersToRemove(from: delivered, isStale: resolved.contains)
            if !stale.isEmpty {
                UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: stale)
            }
            done.signal()
        }
        _ = done.wait(timeout: .now() + 2)
    }
}
