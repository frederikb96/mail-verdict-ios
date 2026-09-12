import Foundation
import MailVerdictKit
import Push
import PushEnvelope
import UIKit
import UserNotifications

/// Receives what only an app delegate can — the APNs token, a silent push — plus the notification
/// centre's own callbacks, and hands each to `PushCoordinator`.
@MainActor
final class PushAppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {

    /// Claimed before launch finishes: a tap that started the app is handed over once, at launch,
    /// and dropped if nobody is the delegate yet.
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
    ) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        Task { await PushCoordinator.shared.applicationDidLaunch() }
        return true
    }

    func application(
        _ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data
    ) {
        PushCoordinator.shared.didReceive(apnsToken: PushTokenEncoding.hex(deviceToken))
    }

    func application(
        _ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: Error
    ) {
        PushCoordinator.shared.registrationFailed(error.mvUserMessage)
    }

    /// The silent read-sync push. Delivered only because `Config/Info.plist` declares the
    /// `remote-notification` background mode; a force-quit app never gets it, by Apple's design.
    func application(
        _ application: UIApplication, didReceiveRemoteNotification userInfo: [AnyHashable: Any],
        fetchCompletionHandler completionHandler: @escaping (UIBackgroundFetchResult) -> Void
    ) {
        Task {
            await PushCoordinator.shared.backgroundWake()
            completionHandler(.newData)
        }
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter, willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        // Only the parsed id crosses to the main actor; the notification itself is not `Sendable`.
        let messageId = (notification.request.content.userInfo[PushNotificationKeys.messageId] as? String)
            .flatMap(UUID.init(uuidString:))
        return await PushCoordinator.shared.presentationOptions(messageId: messageId)
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse
    ) async {
        let payload = Self.stringPayload(response.notification.request.content.userInfo)
        switch response.actionIdentifier {
        case PushNotificationKeys.markReadAction:
            await PushCoordinator.shared.markRead(userInfo: payload)
        case UNNotificationDefaultActionIdentifier:
            await PushCoordinator.shared.handleTap(userInfo: payload)
        default:
            break
        }
    }

    /// Everything the extension writes into `userInfo` is a string; anything else there (the
    /// `aps` dictionary, the sealed envelope) is not needed past this point.
    private nonisolated static func stringPayload(_ userInfo: [AnyHashable: Any]) -> [String: String] {
        var payload: [String: String] = [:]
        for (key, value) in userInfo {
            guard let key = key as? String, let value = value as? String else { continue }
            payload[key] = value
        }
        return payload
    }
}
