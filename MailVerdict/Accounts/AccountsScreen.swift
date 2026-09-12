import MailVerdictKit
import SwiftUI

/// Accounts list — a stub until S7 replaces this file with the real list, add/edit form and
/// status chips.
struct AccountsScreen: View {
    let environment: AppEnvironment
    let connection: AppEnvironment.Connection

    var body: some View {
        Text("Accounts")
            .navigationTitle("Accounts")
            .accessibilityIdentifier("accounts-stub")
            #if DEBUG
                .screenshotReady(route: .accounts, environment: environment, connection: connection)
            #endif
    }
}
