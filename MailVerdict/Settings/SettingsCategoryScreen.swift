import MailVerdictKit
import SwiftUI

/// One generic server-settings category — a stub until S7 replaces this file with the real
/// order-preserving form.
struct SettingsCategoryScreen: View {
    let category: String
    let environment: AppEnvironment
    let connection: AppEnvironment.Connection

    var body: some View {
        Text(category)
            .navigationTitle(category.capitalized)
            .accessibilityIdentifier("settings-category-stub")
            #if DEBUG
                .screenshotReady(
                    route: .settingsCategory(category), environment: environment, connection: connection
                )
            #endif
    }
}
