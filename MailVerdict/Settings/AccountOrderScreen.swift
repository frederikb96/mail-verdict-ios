import MailVerdictKit
import SwiftUI

/// Account display order — a stub until S7 replaces this file with the real drag-to-reorder list.
struct AccountOrderScreen: View {
    let environment: AppEnvironment
    let connection: AppEnvironment.Connection

    var body: some View {
        Text("Account Order")
            .navigationTitle("Account Order")
            .accessibilityIdentifier("accountorder-stub")
            #if DEBUG
                .screenshotReady(route: .accountOrder, environment: environment, connection: connection)
            #endif
    }
}
