import MailVerdictKit
import SwiftUI

/// The app's outermost screen: the gate, and — once connected — the one `NavigationStack` every
/// pushed `Route` lives on.
struct RootView: View {
    @State private var environment = AppEnvironment()
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        content
            .preferredColorScheme(environment.colorScheme)
            .onChange(of: scenePhase) { _, newPhase in
                environment.handleScenePhaseChange(to: newPhase)
            }
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

            // The undo-send capsule's host slot — S3 adds `UndoSendCapsule` here, above the
            // toast overlay, the one file it is allowed to add to Shell (systems design's own
            // slicing rule). Deliberately empty until then.
        }
        .sheet(item: Bindable(environment).presentedCompose) { intent in
            ComposerScreen(intent: intent, environment: environment, connection: connection)
        }
    }

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
            UnifiedViewsScreen(environment: environment, connection: connection)
        case .accountOrder:
            AccountOrderScreen(environment: environment, connection: connection)
        case .notificationSettings:
            NotificationSettingsScreen(environment: environment, connection: connection)
        case .accounts:
            AccountsScreen(environment: environment, connection: connection)
        case .account(let accountId):
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
