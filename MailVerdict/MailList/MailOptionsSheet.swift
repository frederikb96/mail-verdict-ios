import MailVerdictKit
import SwiftUI

/// The Options set for one row, from a short left swipe — the same groups the long-press
/// context menu shows, both built from `MessageActionSet.actions(for:)`.
struct MailOptionsSheet: View {
    let header: MVMailRowData
    let groups: [MVMessageActionGroup]
    /// Grouped by conversation, row actions act on the conversation's latest message; the sheet
    /// says so rather than leaving it to be inferred.
    let actsOnLatestInConversation: Bool
    let verdictIsSpam: Bool?
    let onAction: (MVMessageUIAction) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var detent: PresentationDetent = .large

    var body: some View {
        NavigationStack {
            List {
                Section {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(header.senderName).font(.headline).lineLimit(1)
                        if let subject = header.subject {
                            Text(subject).font(.subheadline).foregroundStyle(.secondary).lineLimit(2)
                        }
                        if actsOnLatestInConversation {
                            Text("Latest message in conversation").font(.caption).foregroundStyle(.tertiary)
                        }
                    }
                }
                ForEach(Array(groups.enumerated()), id: \.offset) { _, group in
                    section(for: group)
                }
            }
            .navigationTitle("Options")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        // Respond/Verdict are a couple of icon buttons; Mark, Star, Move, Junk, Archive and
        // Delete are the rows someone actually came here for — opening at `.medium` left every
        // one of those below the fold. Starting at `.large` still lets a drag down to `.medium`.
        .presentationDetents([.medium, .large], selection: $detent)
        .accessibilityIdentifier("mail-options-sheet")
    }

    @ViewBuilder
    private func section(for group: MVMessageActionGroup) -> some View {
        switch group.kind {
        case .respond, .verdict:
            Section {
                HStack(spacing: 8) {
                    ForEach(group.actions, id: \.title) { action in
                        Button {
                            choose(action)
                        } label: {
                            VStack(spacing: 4) {
                                Image(systemName: action.symbol).font(.title3)
                                Text(action.title).font(.caption).lineLimit(1)
                            }
                            .frame(maxWidth: .infinity, minHeight: 44)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.borderless)
                        .accessibilityIdentifier("options-\(action.title)")
                    }
                }
            } header: {
                if group.kind == .verdict {
                    Text(verdictIsSpam == true ? "Classified as spam" : "Classified as not spam")
                }
            }
        default:
            Section {
                ForEach(group.actions, id: \.title) { action in
                    Button(role: action.isDestructive ? .destructive : nil) {
                        choose(action)
                    } label: {
                        Label(action.title, systemImage: action.symbol)
                    }
                    .foregroundStyle(
                        action.isDestructive ? AnyShapeStyle(MVPalette.destructive) : AnyShapeStyle(.primary)
                    )
                    .accessibilityIdentifier("options-\(action.title)")
                }
            }
        }
    }

    /// Recorded and dismissed; the list runs the action once the sheet has gone, so an action
    /// that presents something of its own (the Move picker, a confirmation) is never presented
    /// over a sheet on its way out.
    private func choose(_ action: MVMessageUIAction) {
        onAction(action)
        dismiss()
    }
}
