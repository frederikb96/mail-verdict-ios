import MailVerdictKit
import SwiftUI

/// The composer sheet — a stub until S3 replaces this file with the real rich-text editor.
/// `RootView`'s `.sheet(item:)` already handles presentation and dismissal; this only has to
/// read `intent`.
struct ComposerScreen: View {
    let intent: ComposeIntent
    let environment: AppEnvironment
    let connection: AppEnvironment.Connection

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Text(description)
                .navigationTitle(title)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") { dismiss() }
                    }
                }
        }
        .accessibilityIdentifier("composer-stub")
    }

    private var title: String {
        switch intent.kind {
        case .new: return "New Message"
        case .reply: return "Reply"
        case .replyAll: return "Reply All"
        case .forward: return "Forward"
        case .draft: return "Draft"
        case .mailto: return "New Message"
        case .undoRestore: return "Restored Message"
        }
    }

    private var description: String {
        "\(intent.kind)"
    }
}
