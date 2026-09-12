import MailVerdictKit
import SwiftUI

/// Unified Views setup — a stub until S7 replaces this file with the real editor.
struct UnifiedViewsScreen: View {
    let environment: AppEnvironment
    let connection: AppEnvironment.Connection

    var body: some View {
        Text("Unified Views")
            .navigationTitle("Unified Views")
            .accessibilityIdentifier("unifiedviews-stub")
            #if DEBUG
                .screenshotReady(route: .unifiedViews, environment: environment, connection: connection)
            #endif
    }
}
