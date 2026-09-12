import MailVerdictKit
import SwiftUI

/// Spam Review — a stub until S6 replaces this file with the real triage list.
struct SpamReviewScreen: View {
    let environment: AppEnvironment
    let connection: AppEnvironment.Connection

    var body: some View {
        Text("Spam Review")
            .navigationTitle("Spam Review")
            .accessibilityIdentifier("spamreview-stub")
            #if DEBUG
                .screenshotReady(route: .spamReview, environment: environment, connection: connection)
            #endif
    }
}
