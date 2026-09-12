import MailVerdictKit
import SwiftUI

/// Remote-image exceptions — a stub until S7 replaces this file with the real list.
struct ImageExceptionsScreen: View {
    let accountId: UUID
    let environment: AppEnvironment
    let connection: AppEnvironment.Connection

    var body: some View {
        Text("Image Exceptions")
            .navigationTitle("Image Exceptions")
            .accessibilityIdentifier("imageexceptions-stub")
            #if DEBUG
                .screenshotReady(
                    route: .imageExceptions(accountId), environment: environment, connection: connection
                )
            #endif
    }
}
