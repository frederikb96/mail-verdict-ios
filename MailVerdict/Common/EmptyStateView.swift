import SwiftUI

/// A centred icon, a message, and an optional single action — every screen's "nothing here"
/// state, shared so every screen gets one rather than each writing its own.
struct EmptyStateView: View {
    let systemImage: String
    let message: String
    var actionTitle: String? = nil
    var action: (() -> Void)? = nil

    var body: some View {
        ContentUnavailableView {
            Label(message, systemImage: systemImage)
        } actions: {
            if let actionTitle, let action {
                Button(actionTitle, action: action)
            }
        }
    }
}
