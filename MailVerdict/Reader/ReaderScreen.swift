import MailVerdictKit
import SwiftUI

/// The reader pager — a stub until S2 replaces this file with the real three-slot paging
/// `UIScrollView` of `WKWebView` pages. `context` already carries the source list and message
/// id `ReaderListSource`/`MessagePlaceResolver` resolved.
struct ReaderScreen: View {
    let context: ReaderContext
    let environment: AppEnvironment
    let connection: AppEnvironment.Connection

    var body: some View {
        VStack(spacing: 12) {
            Text("Reader").font(.title2)
            Text(context.messageId.uuidString).font(.footnote).foregroundStyle(.secondary)
        }
        .navigationTitle("Message")
        .accessibilityIdentifier("reader-stub")
    }
}
