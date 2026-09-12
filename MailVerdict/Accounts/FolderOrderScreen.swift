import MailVerdictKit
import SwiftUI

/// Folder order and visibility — a stub until S7 replaces this file with the real drag-to-reorder
/// list.
struct FolderOrderScreen: View {
    let accountId: UUID
    let environment: AppEnvironment
    let connection: AppEnvironment.Connection

    var body: some View {
        Text("Folder Order & Visibility")
            .navigationTitle("Folders")
            .accessibilityIdentifier("folderorder-stub")
            #if DEBUG
                .screenshotReady(route: .folderOrder(accountId), environment: environment, connection: connection)
            #endif
    }
}
