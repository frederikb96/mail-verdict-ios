import MailVerdictKit
import SwiftUI

/// The bell — a stub until S6 replaces this file with the real Mail/System tabs.
struct NotificationsScreen: View {
    let environment: AppEnvironment
    let connection: AppEnvironment.Connection

    var body: some View {
        Text("Notifications")
            .navigationTitle("Notifications")
            .accessibilityIdentifier("notifications-stub")
    }
}
