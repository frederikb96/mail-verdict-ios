import MailVerdictKit
import SwiftUI

/// One account's detail — a stub until S7 replaces this file with the real status, sync toggle
/// and sub-screen links.
struct AccountDetailScreen: View {
    let accountId: UUID
    let environment: AppEnvironment
    let connection: AppEnvironment.Connection

    var body: some View {
        List {
            NavigationLink("Folder Order & Visibility", value: Route.folderOrder(accountId))
            NavigationLink("Image Exceptions", value: Route.imageExceptions(accountId))
            NavigationLink("Sending Identities", value: Route.identities(accountId))
        }
        .navigationTitle("Account")
        .accessibilityIdentifier("account-detail-stub")
    }
}
