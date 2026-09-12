import Foundation
import MailVerdictKit
import Push
import PushEnvelope
import SwiftUI
import UIKit
import UserNotifications

/// The app side of native push in one place: what the app delegate, the notification centre's
/// callbacks, the shell and the settings screen all call.
///
/// Every decision — when to register, what to withdraw, where a tap leads — is made in the `Push`
/// package, where it is tested on Linux. This holds what needs UIKit or `UserNotifications`, and
/// the wiring between them.
@MainActor
final class PushCoordinator {
    static let shared = PushCoordinator()

    private let records = PushRecordStore()
    /// The shell's environment once it exists. A background launch — a silent read-sync wake, Mark
    /// as Read on a notification — has none and builds a short-lived one, which reads the same
    /// stored server URL and credential the shell would.
    private weak var attachedEnvironment: AppEnvironment?
    /// This launch's APNs token, handed over after `registerForRemoteNotifications()`.
    private var apnsToken: String?
    private var pendingTap: PushTapTarget?
    private var isRefreshing = false
    private var settings: (origin: String, store: NotificationSettingsStore)?
    /// Stands in for the shell while none is attached. Its live-event stream is closed at once:
    /// background work needs only the API client, and a stream nobody reads would stay open.
    private var backgroundEnvironment: AppEnvironment?
    private weak var subscribedHub: LiveEventHub?
    private var hubToken: MVSubscriptionToken?

    #if DEBUG
        /// Fixture mode's stand-in for the system permission, which a simulator run cannot grant.
        var fixtureAuthorization: PushAuthorization?
    #endif

    private struct Context {
        let origin: String
        let backend: MVApiClient
    }

    private func context() -> Context? {
        let environment = attachedEnvironment ?? makeBackgroundEnvironment()
        guard let connection = environment.connection else { return nil }
        return Context(origin: Self.serverOrigin(environment), backend: connection.apiClient)
    }

    private func makeBackgroundEnvironment() -> AppEnvironment {
        if let backgroundEnvironment { return backgroundEnvironment }
        let environment = AppEnvironment()
        environment.connection?.liveEventHub.disconnect()
        backgroundEnvironment = environment
        return environment
    }

    static func serverOrigin(_ environment: AppEnvironment) -> String {
        PushServerOrigin.origin(of: environment.backendURL) ?? environment.backendURL
    }

    // MARK: Lifecycle

    /// Re-asks APNs for this install's token when notifications are on and permitted. Never shows
    /// a prompt, so it is safe on every launch; the token's arrival is what may refresh.
    func applicationDidLaunch() async {
        UNUserNotificationCenter.current().setNotificationCategories([Self.mailCategory()])
        guard await authorization() == .authorized, let context = context(),
            records.load(serverOrigin: context.origin)?.isEnabled == true
        else {
            return
        }
        UIApplication.shared.registerForRemoteNotifications()
    }

    /// Called again whenever the shell's connection changes, since a new connection brings a new
    /// live-event hub to listen to.
    func attach(_ environment: AppEnvironment) {
        attachedEnvironment = environment
        backgroundEnvironment = nil
        let hub = environment.connection?.liveEventHub
        if hub !== subscribedHub {
            if let subscribedHub, let hubToken { subscribedHub.unsubscribe(hubToken) }
            subscribedHub = hub
            hubToken = hub?.subscribe(self)
        }
        consumePendingTap()
        publishDebugState()
    }

    func didBecomeActive() async {
        await reconcile()
        await refreshIfNeeded()
    }

    /// The server's silent read-sync push.
    func backgroundWake() async {
        await reconcile()
    }

    // MARK: Registration

    func beginRegistration() {
        UIApplication.shared.registerForRemoteNotifications()
    }

    func didReceive(apnsToken token: String) {
        apnsToken = token
        publishDebugState()
        Task { await refreshIfNeeded() }
    }

    func registrationFailed(_ message: String) {
        guard let context = context(), var record = records.load(serverOrigin: context.origin), record.isEnabled,
            !record.isRegistered
        else {
            return
        }
        record.lastError = message
        records.save(record, serverOrigin: context.origin)
        publishDebugState()
        Task { await settings?.store.reload() }
    }

    /// Registers when `PushRefreshPolicy` says so, which on most calls it does not.
    func refreshIfNeeded() async {
        guard !isRefreshing, let token = apnsToken, let context = context(),
            var record = records.load(serverOrigin: context.origin),
            PushRefreshPolicy.needsRefresh(record, apnsToken: token, now: Date())
        else {
            return
        }
        isRefreshing = true
        defer { isRefreshing = false }

        let service = PushRegistrationService(backend: context.backend, installations: PushKeychainInstallationStore())
        do {
            record = try await service.register(apnsToken: token, serverOrigin: context.origin, record: record)
        } catch {
            record.lastError = (error as? PushRegistrationFailure)?.userMessage ?? error.mvUserMessage
        }
        // Turned off while the registration was in flight: that choice stands.
        guard records.load(serverOrigin: context.origin)?.isEnabled == true else { return }
        records.save(record, serverOrigin: context.origin)
        publishDebugState()
        await settings?.store.reload()
    }

    func unregister(_ record: PushRegistrationRecord, origin: String, backend: MVApiClient) async throws {
        try await PushRegistrationService(backend: backend, installations: PushKeychainInstallationStore())
            .unregister(serverOrigin: origin, record: record)
        try? await UNUserNotificationCenter.current().setBadgeCount(0)
        publishDebugState()
    }

    // MARK: Permission

    func authorization() async -> PushAuthorization {
        #if DEBUG
            if let fixtureAuthorization { return fixtureAuthorization }
        #endif
        let current = await UNUserNotificationCenter.current().notificationSettings()
        switch current.authorizationStatus {
        case .notDetermined: return .notDetermined
        case .denied: return .denied
        default: return .authorized
        }
    }

    func requestAuthorization() async -> Bool {
        (try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]))
            ?? false
    }

    // MARK: Settings screen

    /// One store per server, shared by the screen and its fixture-mode screenshot step.
    func settingsStore(environment: AppEnvironment, connection: AppEnvironment.Connection) -> NotificationSettingsStore
    {
        let origin = Self.serverOrigin(environment)
        if let settings, settings.origin == origin { return settings.store }

        let backend = connection.apiClient
        let store = NotificationSettingsStore(
            dependencies: .init(
                backend: backend, records: records, serverOrigin: origin,
                authorization: { await PushCoordinator.shared.authorization() },
                requestAuthorization: { await PushCoordinator.shared.requestAuthorization() },
                beginRegistration: { PushCoordinator.shared.beginRegistration() },
                unregister: { record in
                    try await PushCoordinator.shared.unregister(record, origin: origin, backend: backend)
                }
            ))
        settings = (origin, store)
        return store
    }

    // MARK: Delivered notifications

    private static func mailCategory() -> UNNotificationCategory {
        // No `.foreground`: marking read runs in the background with the stored credential, and
        // the server's read-sync then clears the same banner on every other device.
        let markRead = UNNotificationAction(
            identifier: PushNotificationKeys.markReadAction, title: "Mark as Read", options: [])
        return UNNotificationCategory(
            identifier: PushNotificationKeys.mailCategory, actions: [markRead], intentIdentifiers: [], options: [])
    }

    /// Withdraws banners whose alert is gone and sets the badge from the server.
    func reconcile() async {
        guard let context = context() else { return }
        let record = records.load(serverOrigin: context.origin)
        let center = UNUserNotificationCenter.current()
        let delivered = await center.deliveredNotifications().map {
            DeliveredNotification(identifier: $0.request.identifier, userInfo: $0.request.content.userInfo)
        }
        let outcome = await PushReconciler(backend: context.backend).reconcile(
            delivered: delivered, subscriptionId: record?.isRegistered == true ? record?.subscriptionId : nil)
        if !outcome.identifiersToRemove.isEmpty {
            center.removeDeliveredNotifications(withIdentifiers: outcome.identifiersToRemove)
        }
        if let badge = outcome.badge {
            try? await center.setBadgeCount(badge)
        }
    }

    /// APNs is the one source of banners — the app never raises its own from live events — so
    /// the only thing to decide in front is whether this one would announce what is on screen.
    func presentationOptions(messageId: UUID?) -> UNNotificationPresentationOptions {
        let path = attachedEnvironment?.navigationPath ?? []
        return PushPresentation.shouldPresent(messageId: messageId, navigationPath: path)
            ? [.banner, .list, .sound, .badge] : []
    }

    /// Parked until the shell has a connection to navigate on: a tap that launched the app arrives
    /// before there is a navigation stack, or even a signed-in user.
    func handleTap(userInfo: [String: String]) {
        pendingTap = PushTapTarget(userInfo: userInfo)
        consumePendingTap()
        Task { await refreshIfNeeded() }
    }

    func markRead(userInfo: [String: String]) async {
        guard let messageId = userInfo[PushNotificationKeys.messageId].flatMap(UUID.init(uuidString:)),
            let context = context()
        else {
            return
        }
        _ = try? await context.backend.markRead(messageId: messageId)
        await reconcile()
    }

    private func consumePendingTap() {
        guard let target = pendingTap, let environment = attachedEnvironment,
            let connection = environment.connection
        else {
            return
        }
        pendingTap = nil
        switch target {
        case .mailboxes:
            environment.navigationPath = []
        case .notifications:
            environment.navigationPath = [.notifications]
        case .message(let messageId):
            Task {
                switch await connection.placeResolver.resolve(messageId: messageId) {
                case .route(let path):
                    environment.navigationPath = path
                case .notFound(let message):
                    environment.toasts.show(MVToast(variant: .info, message: message))
                }
            }
        }
    }

    // MARK: Debug

    private func publishDebugState() {
        #if DEBUG
            let context = context()
            let record = context.flatMap { records.load(serverOrigin: $0.origin) }
            let formatter = ISO8601DateFormatter()
            PushDebugState.shared.update(
                PushDebugSnapshot(
                    serverOrigin: context?.origin, enabled: record?.isEnabled ?? false,
                    registered: record?.isRegistered ?? false, hasAPNsToken: apnsToken != nil,
                    ticketExpiresAt: record?.ticketExpiresAt.map(formatter.string(from:)),
                    lastUpsertAt: record?.lastUpsertAt.map(formatter.string(from:)), lastError: record?.lastError,
                    pendingTap: pendingTap.map { "\($0)" }))
        #endif
    }
}

/// The shell's one hook into push: hands over its environment, and reports the app coming to the
/// front, where delivered banners are reconciled and a stale registration refreshed.
struct PushCoordination: ViewModifier {
    let environment: AppEnvironment
    @Environment(\.scenePhase) private var scenePhase

    func body(content: Content) -> some View {
        content
            .task {
                PushCoordinator.shared.attach(environment)
                await PushCoordinator.shared.didBecomeActive()
            }
            .onChange(of: environment.connection == nil) { _, _ in
                PushCoordinator.shared.attach(environment)
            }
            .onChange(of: scenePhase) { _, phase in
                guard phase == .active else { return }
                Task { await PushCoordinator.shared.didBecomeActive() }
            }
    }
}

extension View {
    func pushCoordination(_ environment: AppEnvironment) -> some View {
        modifier(PushCoordination(environment: environment))
    }
}
