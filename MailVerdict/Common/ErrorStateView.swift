import MailVerdictKit
import SwiftUI

/// A centred icon, a short human-readable message, and a Try Again button — every screen's error
/// state, replacing the web's error boundaries.
struct ErrorStateView: View {
    let message: String
    var technicalDetail: String? = nil
    let retry: () -> Void

    /// `error.mvUserMessage` rather than `"\(error)"` — the latter is an `NSError`'s own
    /// `Domain=...Code=...UserInfo={...}` dump, never something to show on screen.
    init(error: Error, retry: @escaping () -> Void) {
        self.message = error.mvUserMessage
        self.technicalDetail = error.mvTechnicalDetail
        self.retry = retry
    }

    init(message: String, retry: @escaping () -> Void) {
        self.message = message
        self.retry = retry
    }

    var body: some View {
        ContentUnavailableView {
            Label("Something went wrong", systemImage: "exclamationmark.triangle")
        } description: {
            VStack(spacing: 4) {
                Text(message)
                if let technicalDetail {
                    DisclosureGroup("Details") {
                        Text(technicalDetail)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                }
            }
        } actions: {
            Button("Try Again", action: retry)
        }
    }
}
