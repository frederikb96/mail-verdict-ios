import MailVerdictKit
import SwiftUI

/// New Mail Notifications — a stub until block 5's push slice replaces this file with the real
/// registration and folder-scope screen (row 38 note 3: this screen moved here from Settings).
struct NotificationSettingsScreen: View {
    let environment: AppEnvironment
    let connection: AppEnvironment.Connection

    var body: some View {
        Text("New Mail Notifications")
            .navigationTitle("New Mail Notifications")
            .accessibilityIdentifier("notificationsettings-stub")
            #if DEBUG
                .screenshotReady(route: .notificationSettings, environment: environment, connection: connection)
            #endif
    }
}
