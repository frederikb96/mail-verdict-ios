import MailVerdictKit
import SwiftUI

/// "Add rule" on the open mail: a sentence in, one proposed rule change out, accepted or
/// declined. Dismissing the sheet drops a request still running.
struct RuleAssistantSheet: View {
    @State private var store: RuleAssistantStore
    let onSaved: () -> Void
    @Environment(\.dismiss) private var dismiss

    init(messageId: UUID, api: MVApiClient, onSaved: @escaping () -> Void) {
        self._store = State(initialValue: RuleAssistantStore(messageId: messageId, apiClient: api))
        self.onSaved = onSaved
    }

    var body: some View {
        NavigationStack {
            content
                .navigationTitle("Add Rule")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") { dismiss() }
                            .disabled(store.isAccepting)
                    }
                }
        }
        .interactiveDismissDisabled(store.isAccepting)
        .onDisappear { store.cancel() }
        .onChange(of: store.phase) { _, phase in
            guard phase == .accepted else { return }
            onSaved()
            dismiss()
        }
    }

    @ViewBuilder
    private var content: some View {
        switch store.phase {
        case .prompt:
            RuleAssistantPromptForm(store: store)
        case .running:
            VStack(spacing: 12) {
                ProgressView()
                Text("Working out a rule…").foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .result(let response, let change):
            RuleAssistantProposal(
                response: response, change: change, isAccepting: store.isAccepting,
                onAccept: { store.accept() },
                onDecline: {
                    store.cancel()
                    dismiss()
                })
        case .empty(let message):
            RuleAssistantNotice(message: message, isError: false) { dismiss() }
        case .failed(let message):
            RuleAssistantNotice(message: message, isError: true) { dismiss() }
        case .accepted:
            EmptyView()
        }
    }
}

private struct RuleAssistantPromptForm: View {
    let store: RuleAssistantStore
    @FocusState private var isFocused: Bool

    private var promptBinding: Binding<String> {
        Binding(
            get: { store.promptText },
            set: { store.promptText = String($0.prefix(RuleAssistantRequest.maxPromptLength)) })
    }

    var body: some View {
        Form {
            Section {
                TextField("These should go to Newsletter too", text: promptBinding, axis: .vertical)
                    .lineLimit(3...8)
                    .focused($isFocused)
                    .accessibilityLabel("What should the rule do?")
            } footer: {
                Text("Say in one sentence what should happen to mail like the one you have open.")
            }
            Section {
                Button("Propose Rule") { store.send() }
                    .disabled(!store.canSend)
            }
        }
        .task { isFocused = true }
    }
}

private struct RuleAssistantProposal: View {
    let response: RuleAssistantResponse
    let change: RuleAssistantChange
    let isAccepting: Bool
    let onAccept: () -> Void
    let onDecline: () -> Void

    var body: some View {
        List {
            Section { Text(response.message) }
            Section(change.title) {
                if let effects = change.effectsText {
                    RuleTextBlock(label: "What this rule does", text: effects)
                }
                if let before = change.beforeText {
                    RuleTextBlock(label: "Now", text: before)
                }
                RuleTextBlock(label: "Proposed", text: change.afterText)
            }
            if let preview = response.preview {
                RuleAssistantPreviewSection(preview: preview)
            }
            if !response.warnings.isEmpty {
                Section {
                    ForEach(response.warnings, id: \.self) { warning in
                        Text(warning).foregroundStyle(.orange)
                    }
                }
            }
        }
        .safeAreaInset(edge: .bottom) { actionBar }
    }

    private var actionBar: some View {
        HStack(spacing: 12) {
            Button("Decline", action: onDecline)
                .buttonStyle(.bordered)
                .disabled(isAccepting)
            Button(action: onAccept) {
                if isAccepting {
                    ProgressView()
                } else {
                    Text("Accept")
                }
            }
            .buttonStyle(.borderedProminent)
            .disabled(isAccepting)
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
        .padding()
        .background(.bar)
    }
}

private struct RuleTextBlock: View {
    let label: String
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).font(.caption.weight(.medium)).foregroundStyle(.secondary)
            Text(text)
                .font(.caption.monospaced())
                .textSelection(.enabled)
        }
    }
}

private struct RuleAssistantPreviewSection: View {
    let preview: RuleAssistantPreview

    var body: some View {
        Section {
            Text(preview.summaryLine)
            ForEach(Array(preview.examples.enumerated()), id: \.offset) { _, example in
                Text("\(example.fromAddr) — \(example.subject)")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
    }
}

private struct RuleAssistantNotice: View {
    let message: String
    let isError: Bool
    let onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(message)
                .foregroundStyle(isError ? Color.red : Color.primary)
            Button("Close", action: onClose).buttonStyle(.bordered)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding()
    }
}
