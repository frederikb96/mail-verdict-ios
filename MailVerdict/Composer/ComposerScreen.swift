import MailVerdictKit
import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// The composer sheet, for every way a message starts: new, reply, reply all, forward, a reopened
/// draft, a `mailto:` link, or a cancelled send given back. Mail's layout — recipient rows that
/// scroll away with the body, Cc/Bcc/From folded into one row until needed, attachments above the
/// body, the quoted original below it.
struct ComposerScreen: View {
    let intent: ComposeIntent
    let environment: AppEnvironment
    let connection: AppEnvironment.Connection

    @State private var store: ComposerStore
    @State private var suggestions: RecipientSuggestionStore
    @State private var activeField: ComposeRecipientField?
    @State private var editorHeight: CGFloat = 0
    @State private var confirmingClose = false
    @State private var showsPhotoPicker = false
    @State private var showsFileImporter = false
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase

    init(intent: ComposeIntent, environment: AppEnvironment, connection: AppEnvironment.Connection) {
        self.intent = intent
        self.environment = environment
        self.connection = connection
        let services = ComposerServices.shared
        var restoration: UndoSendRestoration?
        if case .undoRestore(let pendingSendId) = intent.kind {
            restoration = services.undoSend?.restoration(for: pendingSendId)
        }
        _store = State(
            initialValue: ComposerStore(
                intent: intent, dependencies: .live(client: connection.apiClient, recovery: services.recovery),
                undoRestoration: restoration))
        let client = connection.apiClient
        _suggestions = State(
            initialValue: RecipientSuggestionStore { query in try await client.searchContacts(query: query) })
    }

    var body: some View {
        NavigationStack {
            content
                .navigationTitle(store.phase == .sending ? "Sending…" : store.title)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar { toolbar }
        }
        .interactiveDismissDisabled(store.isDirty || store.phase == .sending)
        .background(DismissAttemptObserver { attemptClose() })
        .confirmationDialog("Save this message?", isPresented: $confirmingClose, titleVisibility: .hidden) {
            Button("Save Draft") { Task { await submit(.draft) } }
            Button("Discard Changes", role: .destructive) { discardAndClose() }
            Button("Cancel", role: .cancel) {}
        }
        .sheet(isPresented: $showsPhotoPicker) {
            ComposerPhotoPicker(onFinish: { showsPhotoPicker = false }, onPick: { store.addAttachments($0) })
                .ignoresSafeArea()
        }
        .fileImporter(isPresented: $showsFileImporter, allowedContentTypes: [.item], allowsMultipleSelection: true) {
            result in
            guard case .success(let urls) = result else { return }
            Task { store.addAttachments(await ComposerFileReader.read(urls)) }
        }
        .task { await run() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .background { store.saveRecoverySnapshot() }
        }
        .onDisappear { closeDown() }
        #if DEBUG
            .screenshotReady(compose: intent, environment: environment, connection: connection)
        #endif
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        switch store.phase {
        case .loading:
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .loadFailed(let message):
            ErrorStateView(message: message) { Task { await store.load() } }
        case .editing, .sending:
            form
                .disabled(store.phase == .sending)
                .opacity(store.phase == .sending ? 0.5 : 1)
                .overlay {
                    if store.phase == .sending { ProgressView() }
                }
        }
    }

    private var form: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                banners
                RecipientTokenField(
                    field: .to, store: store, activeField: $activeField, onQueryChange: suggestions.update)
                if let hint = store.sendHint {
                    Text(hint)
                        .font(.footnote)
                        .foregroundStyle(MVPalette.destructive)
                        .padding(.horizontal, 16)
                        .padding(.bottom, 6)
                }
                Divider()
                if suggestingField != .to {
                    headerRowsAfterTo
                }
                bodySection
                    .overlay(alignment: .top) {
                        if let field = suggestingField { suggestionList(for: field) }
                    }
            }
        }
        .scrollDismissesKeyboard(.interactively)
        .accessibilityIdentifier("composer")
    }

    @ViewBuilder
    private var headerRowsAfterTo: some View {
        if store.showsCcBcc {
            RecipientTokenField(field: .cc, store: store, activeField: $activeField, onQueryChange: suggestions.update)
            Divider()
            if suggestingField != .cc {
                RecipientTokenField(
                    field: .bcc, store: store, activeField: $activeField, onQueryChange: suggestions.update)
                Divider()
                if suggestingField != .bcc {
                    if store.showsFromPicker {
                        fromRow
                        Divider()
                    }
                    subjectRow
                }
            }
        } else {
            Button {
                store.showsCcBcc = true
            } label: {
                HStack(spacing: 4) {
                    Text(store.showsFromPicker ? "Cc/Bcc, From:" : "Cc/Bcc")
                        .foregroundStyle(.secondary)
                    if store.showsFromPicker, let from = store.selectedFrom {
                        Text(from.address)
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("composer-cc-bcc-from")
            Divider()
            subjectRow
        }
    }

    /// A new message may send from any account, so its choices are grouped by account; a reply,
    /// forward or draft only ever offers its own account's addresses.
    private var fromRow: some View {
        HStack(spacing: 6) {
            Text("From:")
                .foregroundStyle(.secondary)
            Menu {
                ForEach(fromAccountIds, id: \.self) { accountId in
                    Section(fromAccountIds.count > 1 ? (store.accountName(for: accountId) ?? "") : "") {
                        ForEach(store.fromOptions.filter { $0.accountId == accountId }) { option in
                            Button {
                                store.selectedFromKey = option.key
                            } label: {
                                if option.key == store.selectedFrom?.key {
                                    Label(option.label, systemImage: "checkmark")
                                } else {
                                    Text(option.label)
                                }
                            }
                        }
                    }
                }
            } label: {
                HStack(spacing: 4) {
                    Text(store.selectedFrom?.label ?? "")
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.caption)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .accessibilityIdentifier("composer-from")
    }

    private var fromAccountIds: [UUID] {
        var seen = Set<UUID>()
        return store.fromOptions.map(\.accountId).filter { seen.insert($0).inserted }
    }

    private var subjectRow: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Text("Subject:")
                    .foregroundStyle(.secondary)
                TextField("", text: Bindable(store).subject)
                    .accessibilityLabel("Subject")
                    .accessibilityIdentifier("composer-subject")
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            Divider()
        }
    }

    private var bodySection: some View {
        VStack(alignment: .leading, spacing: 12) {
            if !store.attachments.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(store.attachments) { attachment in
                            AttachmentChip(attachment: attachment) { store.removeAttachment(id: attachment.id) }
                        }
                    }
                    .padding(.horizontal, 16)
                }
                .padding(.top, 10)
                .accessibilityIdentifier("composer-attachments")
            }
            RichTextEditorView(store: store, height: $editorHeight) { source in
                switch source {
                case .photos: showsPhotoPicker = true
                case .files: showsFileImporter = true
                }
            }
            .frame(height: max(editorHeight, 220))
            if let quote = store.quote {
                QuoteCard(quote: quote) { store.removeQuote() }
                    .padding(.horizontal, 16)
                    .padding(.bottom, 24)
            }
        }
        .frame(minHeight: suggestingField == nil ? 0 : 420, alignment: .top)
    }

    // MARK: - Banners

    @ViewBuilder
    private var banners: some View {
        if !store.unrestoredAttachments.isEmpty {
            let names = store.unrestoredAttachments.joined(separator: ", ")
            banner(
                "Not restored: \(names). Attach \(store.unrestoredAttachments.count == 1 ? "it" : "them") again before sending.",
                tint: MVPalette.destructive)
        }
        if let error = store.submitError {
            banner(error, tint: MVPalette.destructive)
        }
        if store.recoverable != nil {
            HStack(spacing: 10) {
                Text("Recovered unsaved text from an earlier session")
                    .font(.footnote)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Button("Restore") { store.restoreRecovered() }
                    .font(.footnote.weight(.semibold))
                Button {
                    store.dismissRecovered()
                } label: {
                    Image(systemName: "xmark")
                }
                .accessibilityLabel("Dismiss")
            }
            .padding(12)
            .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 10))
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .accessibilityIdentifier("composer-recovery-banner")
        }
    }

    private func banner(_ text: String, tint: Color) -> some View {
        Text(text)
            .font(.footnote)
            .foregroundStyle(tint)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
            .background(tint.opacity(0.1), in: RoundedRectangle(cornerRadius: 10))
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
    }

    // MARK: - Suggestions

    /// The field whose autocomplete is showing; its suggestions cover everything below it, as in
    /// Mail.
    private var suggestingField: ComposeRecipientField? {
        guard let field = activeField, !visibleSuggestions(for: field).isEmpty,
            !(store.recipientText[field] ?? "").trimmingCharacters(in: .whitespaces).isEmpty
        else { return nil }
        return field
    }

    private func visibleSuggestions(for field: ComposeRecipientField) -> [ContactSearchHitOut] {
        let present = Set(store.recipients(field).map { $0.lowercased() })
        return suggestions.results.filter { !present.contains($0.email.lowercased()) }
    }

    private func suggestionList(for field: ComposeRecipientField) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(visibleSuggestions(for: field)) { hit in
                Button {
                    store.addRecipient(hit.email, to: field)
                    suggestions.clear()
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(hit.name.isEmpty ? hit.email : hit.name)
                            .font(.body.weight(.semibold))
                            .foregroundStyle(.primary)
                        if !hit.name.isEmpty {
                            Text(hit.email)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                Divider().padding(.leading, 16)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(Color(.systemBackground))
        .accessibilityIdentifier("composer-suggestions")
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .cancellationAction) {
            Button {
                attemptClose()
            } label: {
                Image(systemName: "xmark")
            }
            .accessibilityLabel("Cancel")
        }
        ToolbarItem(placement: .primaryAction) {
            Menu {
                Button("Save Draft", systemImage: "square.and.arrow.down") { Task { await submit(.draft) } }
                if store.quote != nil {
                    Button("Remove Quoted Text", systemImage: "text.badge.minus") { store.removeQuote() }
                }
                Button("Discard Changes", systemImage: MVSymbols.delete, role: .destructive) { discardAndClose() }
            } label: {
                Image(systemName: MVSymbols.options)
            }
            .accessibilityLabel("More")
            .disabled(store.phase != .editing)
        }
        ToolbarItem(placement: .confirmationAction) {
            Button {
                Task { await submit(.send) }
            } label: {
                Image(systemName: MVSymbols.send)
            }
            .accessibilityLabel("Send")
            .accessibilityIdentifier("composer-send")
            // Tappable while To is empty so the tap can say why nothing happened.
            .opacity(hasRecipient ? 1 : 0.4)
            .disabled(store.phase != .editing)
        }
    }

    private var hasRecipient: Bool {
        !store.recipients(.to).isEmpty
            || !(store.recipientText[.to] ?? "").trimmingCharacters(in: .whitespaces).isEmpty
    }

    // MARK: - Actions

    /// Loads, then snapshots for crash recovery once a second for as long as the sheet is up.
    private func run() async {
        ComposerServices.shared.activeComposer = store
        if store.phase == .loading { await store.load() }
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(1))
            store.saveRecoverySnapshot()
        }
    }

    private func submit(_ kind: OutboxCreateRequest.Kind) async {
        switch await store.submit(kind) {
        case .sent:
            environment.toasts.show(MVToast(variant: .success, message: "Message queued for sending"))
            dismiss()
        case .draftSaved:
            environment.toasts.show(MVToast(variant: .success, message: "Draft saved"))
            dismiss()
        case .pending(let row):
            // The undo capsule carries a staged send; a toast would say the same thing twice.
            ComposerServices.shared.undoSend?.add(row)
            dismiss()
        case .failed, .blocked, .ignored:
            break
        }
    }

    private func attemptClose() {
        guard store.phase != .sending else { return }
        if store.isDirty {
            confirmingClose = true
        } else {
            store.discard()
            dismiss()
        }
    }

    private func discardAndClose() {
        store.discard()
        dismiss()
    }

    private func closeDown() {
        let services = ComposerServices.shared
        if services.activeComposer === store { services.activeComposer = nil }
        if case .undoRestore(let pendingSendId) = intent.kind {
            services.undoSend?.forgetRestoration(for: pendingSendId)
        }
    }
}

/// One attachment in the strip: a thumbnail for an image, the file's kind otherwise, its name and
/// size, and a button to take it off.
private struct AttachmentChip: View {
    let attachment: ComposeAttachment
    let onRemove: () -> Void

    @State private var thumbnail: UIImage?

    var body: some View {
        HStack(spacing: 8) {
            Group {
                if let thumbnail {
                    Image(uiImage: thumbnail)
                        .resizable()
                        .scaledToFill()
                } else {
                    Image(systemName: symbol)
                        .font(.title3)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(width: 36, height: 36)
            .clipShape(RoundedRectangle(cornerRadius: 6))
            VStack(alignment: .leading, spacing: 1) {
                Text(attachment.filename)
                    .font(.footnote)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(formatSize(attachment.sizeBytes))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: 140, alignment: .leading)
            Button(action: onRemove) {
                Image(systemName: "xmark.circle.fill")
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Remove \(attachment.filename)")
        }
        .padding(6)
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 10))
        .task(id: attachment.id) {
            guard isImage else { return }
            thumbnail = UIImage(data: attachment.data)?.preparingThumbnail(of: CGSize(width: 96, height: 96))
        }
    }

    private var type: UTType? {
        attachment.contentType.flatMap { UTType(mimeType: $0) }
            ?? UTType(filenameExtension: (attachment.filename as NSString).pathExtension)
    }

    private var isImage: Bool { type?.conforms(to: .image) ?? false }

    private var symbol: String {
        guard let type else { return "doc" }
        if type.conforms(to: .image) { return "photo" }
        if type.conforms(to: .movie) { return "film" }
        if type.conforms(to: .audio) { return "waveform" }
        if type.conforms(to: .pdf) { return "doc.richtext" }
        if type.conforms(to: .archive) { return "doc.zipper" }
        return "doc"
    }
}
