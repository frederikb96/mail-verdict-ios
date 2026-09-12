import MailVerdictKit
import SwiftUI

/// Search — a stub until S5 replaces this file with the real text/semantic search screen.
struct SearchScreen: View {
    let initialQuery: String?
    let environment: AppEnvironment
    let connection: AppEnvironment.Connection

    var body: some View {
        Text(initialQuery ?? "Search")
            .navigationTitle("Search")
            .accessibilityIdentifier("search-stub")
    }
}
