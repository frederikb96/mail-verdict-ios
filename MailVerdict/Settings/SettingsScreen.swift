import MailVerdictKit
import SwiftUI

/// Settings — a stub until S7 replaces this file with the real form.
struct SettingsScreen: View {
    let environment: AppEnvironment
    let connection: AppEnvironment.Connection

    var body: some View {
        List {
            NavigationLink("Unified Views", value: Route.unifiedViews)
            NavigationLink("Account Order", value: Route.accountOrder)
            NavigationLink("New Mail Notifications", value: Route.notificationSettings)
        }
        .navigationTitle("Settings")
        .accessibilityIdentifier("settings-stub")
    }
}
