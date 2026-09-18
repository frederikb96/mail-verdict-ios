import MailVerdictKit
import SwiftUI

/// The app's outermost screen: the gate, and — once connected — the one `NavigationStack` every
/// pushed `Route` lives on.
struct RootView: View {
    @State private var environment = AppEnvironment.shared
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        content
            .preferredColorScheme(environment.colorScheme)
            .onChange(of: scenePhase) { _, newPhase in
                environment.handleScenePhaseChange(to: newPhase)
            }
            .pushCoordination(environment)
    }

    @ViewBuilder
    private var content: some View {
        switch environment.router.gate {
        case .needsConfiguration:
            SignInView(environment: environment, reason: .firstLaunch)
        case .tokenRejected:
            SignInView(environment: environment, reason: .rejected(environment.lastAuthFailure))
        case .ready:
            if let connection = environment.connection {
                ConnectedShell(environment: environment, connection: connection)
            } else {
                // `ready` without a connection should be unreachable; showing sign-in is the only
                // state a user can act on, and a blank screen is the alternative.
                SignInView(environment: environment, reason: .firstLaunch)
            }
        }
    }
}

/// Everything behind the connection gate: the navigation stack rooted at Mailboxes, the composer
/// sheet, and the overlays that sit above both.
private struct ConnectedShell: View {
    let environment: AppEnvironment
    let connection: AppEnvironment.Connection

    var body: some View {
        ZStack {
            NavigationStack(path: Bindable(environment).navigationPath) {
                MailboxesScreen(environment: environment, connection: connection)
                    .navigationDestination(for: Route.self) { route in
                        destination(for: route)
                    }
            }
            .onChange(of: environment.navigationPath) { _, _ in
                environment.persistNavigationPath()
            }

            ToastOverlay(store: environment.toasts)

            UndoSendCapsule(environment: environment, connection: connection)
        }
        .environment(\.mvImageLoader, connection.imageLoader)
        .environment(\.mvApiClient, connection.apiClient)
        .sheet(item: Bindable(environment).presentedCompose) { intent in
            ComposerScreen(intent: intent, environment: environment, connection: connection)
        }
        .task {
            ReaderWebKit.prewarm(api: connection.apiClient)
        }
        #if DEBUG
            .task {
                navigateToFixtureScreenshotTargetIfNeeded()
            }
        #endif
    }

    #if DEBUG
        /// Fixture mode's own navigation trigger — `-MVFixtureScreen <id>` names a
        /// `ScreenshotRegistry` entry, and a `.route`/`.compose` entry needs this push or sheet
        /// presentation before its destination screen can ever appear and report itself ready.
        /// `.root` needs nothing: Mailboxes is already on screen. Never reports readiness
        /// itself — that stays the destination screen's own job (`View.screenshotReady*`), so a
        /// navigation that silently fails to land still times out `/screen/current` instead of
        /// lying about it.
        private func navigateToFixtureScreenshotTargetIfNeeded() {
            guard MVFixtureLaunch.isEnabled(), let targetId = MVFixtureLaunch.targetScreenId() else { return }
            DebugLogBuffer.shared.append(.info, "navigation", "fixture target resolved: \(targetId)")
            guard let entry = ScreenshotRegistry.entry(id: targetId) else {
                DebugLogBuffer.shared.append(
                    .info, "navigation", "fixture target '\(targetId)': no matching registry entry")
                return
            }
            DebugLogBuffer.shared.append(
                .info, "navigation", "fixture target '\(targetId)': entry found, destination=\(entry.destination)")
            switch entry.destination {
            case .root:
                break
            case .route(let route):
                environment.navigationPath = [route]
                DebugLogBuffer.shared.append(
                    .info, "navigation",
                    "fixture target '\(targetId)': navigationPath set to \(environment.navigationPath)")
            case .compose(let intent):
                environment.presentedCompose = intent
            }
        }
    #endif

    @ViewBuilder
    private func destination(for route: Route) -> some View {
        switch route {
        case .list(let scope, let aroundMessageId):
            MailListScreen(
                scope: scope, aroundMessageId: aroundMessageId, environment: environment, connection: connection)
        case .reader(let context):
            ReaderScreen(context: context, environment: environment, connection: connection)
        case .search(let initialQuery):
            SearchScreen(initialQuery: initialQuery, environment: environment, connection: connection)
        case .spamReview:
            SpamReviewScreen(environment: environment, connection: connection)
        case .notifications:
            NotificationsScreen(environment: environment, connection: connection)
        case .settings:
            SettingsScreen(environment: environment, connection: connection)
        case .settingsCategory(let category):
            SettingsCategoryScreen(category: category, environment: environment, connection: connection)
        case .unifiedViews:
            #if DEBUG
                let _ = DebugLogBuffer.shared.append(.info, "navigation", "destination(for:) building .unifiedViews")
            #endif
            UnifiedViewsScreen(environment: environment, connection: connection)
        case .accountOrder:
            AccountOrderScreen(environment: environment, connection: connection)
        case .notificationSettings:
            NotificationSettingsScreen(environment: environment, connection: connection)
        case .accounts:
            AccountsScreen(environment: environment, connection: connection)
        case .account(let accountId):
            #if DEBUG
                let _ = DebugLogBuffer.shared.append(
                    .info, "navigation", "destination(for:) building .account(\(accountId))")
            #endif
            AccountDetailScreen(accountId: accountId, environment: environment, connection: connection)
        case .folderOrder(let accountId):
            FolderOrderScreen(accountId: accountId, environment: environment, connection: connection)
        case .imageExceptions(let accountId):
            ImageExceptionsScreen(accountId: accountId, environment: environment, connection: connection)
        case .identities(let accountId):
            IdentitiesScreen(accountId: accountId, environment: environment, connection: connection)
        }
    }
}
