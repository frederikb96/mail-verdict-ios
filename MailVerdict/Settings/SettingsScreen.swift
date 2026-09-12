import MailVerdictKit
import SwiftUI

/// Settings — appearance, mail-wide preferences, server configuration, accounts, and the
/// connection itself. Every row pushes its own screen; nothing here has a Save button, since each
/// one commits its own change immediately.
struct SettingsScreen: View {
    let environment: AppEnvironment
    let connection: AppEnvironment.Connection

    @State private var accountOrderStore: MVAccountOrderStore?

    var body: some View {
        Form {
            Section("Appearance") {
                ThemePicker(environment: environment)
            }

            Section("Mail") {
                if let accountOrderStore, accountOrderStore.accounts.count >= 2 {
                    NavigationLink("Account Order", value: Route.accountOrder)
                }
                NavigationLink("Unified Views", value: Route.unifiedViews)
                NavigationLink("New Mail Notifications", value: Route.notificationSettings)
                NavigationLink(
                    "Filing and Notifications", value: Route.settingsCategory(MVSettingsCategory.mail.rawValue))
            }

            Section("Sending") {
                NavigationLink("Outbox", value: Route.settingsCategory(MVSettingsCategory.outbox.rawValue))
            }

            Section("Advanced") {
                NavigationLink("AI", value: Route.settingsCategory(MVSettingsCategory.ai.rawValue))
                NavigationLink("Semantic Search", value: Route.settingsCategory(MVSettingsCategory.semantic.rawValue))
                NavigationLink("Retry", value: Route.settingsCategory(MVSettingsCategory.retry.rawValue))
                NavigationLink("Pipeline", value: Route.settingsCategory(MVSettingsCategory.pipeline.rawValue))
            }

            Section("Accounts") {
                NavigationLink("Accounts", value: Route.accounts)
            }

            Section("Connection") {
                LabeledContent("Server", value: environment.backendURL)
                Button("Sign Out", role: .destructive) {
                    environment.signOut()
                }
            }
        }
        .navigationTitle("Settings")
        .accessibilityIdentifier("settings-screen")
        #if DEBUG
            .screenshotReady(route: .settings, environment: environment, connection: connection)
        #endif
        .task {
            let store = accountOrderStore ?? MVAccountOrderStore(apiClient: connection.apiClient)
            accountOrderStore = store
            #if DEBUG
                SettingsDebugServices.shared.activeAccountOrderStore = store
            #endif
            await store.load()
        }
    }
}

/// System / Light / Dark — device-local, applied to the whole window.
private struct ThemePicker: View {
    let environment: AppEnvironment

    private enum Choice: String, CaseIterable, Identifiable {
        case system = "System"
        case light = "Light"
        case dark = "Dark"
        var id: String { rawValue }
    }

    private var choice: Choice {
        switch environment.colorScheme {
        case .light: return .light
        case .dark: return .dark
        default: return .system
        }
    }

    var body: some View {
        Picker("Theme", selection: Binding(get: { choice }, set: { apply($0) })) {
            ForEach(Choice.allCases) { Text($0.rawValue).tag($0) }
        }
    }

    private func apply(_ choice: Choice) {
        switch choice {
        case .system: environment.colorScheme = nil
        case .light: environment.colorScheme = .light
        case .dark: environment.colorScheme = .dark
        }
    }
}
