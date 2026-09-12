import MailVerdictKit
import SwiftUI

/// The message list — a stub until S1 replaces this file with the real `UICollectionView`
/// controller. `scope` and `aroundMessageId` are already threaded through from `Route`, so S1's
/// real implementation only has to read them, never plumb them from `RootView` again.
struct MailListScreen: View {
    let scope: ListScope
    let aroundMessageId: UUID?
    let environment: AppEnvironment
    let connection: AppEnvironment.Connection

    var body: some View {
        List {
            MailRowView(data: .fixture)
        }
        .navigationTitle(title)
        .accessibilityIdentifier("maillist-stub")
    }

    private var title: String {
        switch scope {
        case .folder: return "Folder"
        case .unified(_, let name): return name
        }
    }
}
