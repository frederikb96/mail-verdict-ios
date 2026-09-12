import MailVerdictKit
import SwiftUI

/// Sending identities — a stub until S7 replaces this file with the real list.
struct IdentitiesScreen: View {
    let accountId: UUID
    let environment: AppEnvironment
    let connection: AppEnvironment.Connection

    var body: some View {
        Text("Sending Identities")
            .navigationTitle("Identities")
            .accessibilityIdentifier("identities-stub")
            #if DEBUG
                .screenshotReady(route: .identities(accountId), environment: environment, connection: connection)
            #endif
    }
}
