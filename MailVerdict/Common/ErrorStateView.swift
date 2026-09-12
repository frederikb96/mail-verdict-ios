import SwiftUI

/// A centred icon, the server's own `detail` text, and a Try Again button — every screen's error
/// state, replacing the web's error boundaries.
struct ErrorStateView: View {
    let message: String
    let retry: () -> Void

    var body: some View {
        ContentUnavailableView {
            Label("Something went wrong", systemImage: "exclamationmark.triangle")
        } description: {
            Text(message)
        } actions: {
            Button("Try Again", action: retry)
        }
    }
}
