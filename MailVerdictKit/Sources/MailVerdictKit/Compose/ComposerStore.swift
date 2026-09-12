import Foundation
import Observation

/// Everything the composer reaches outside itself, as closures — the app wires them to
/// `MVApiClient`, a test to canned answers.
public struct ComposerDependencies: Sendable {
    public var listAccounts: @Sendable () async throws -> [AccountResponse]
    public var listIdentities: @Sendable () async throws -> [IdentityResponse]
    public var getMessage: @Sendable (UUID) async throws -> MessageDetail
    public var getQuote: @Sendable (UUID) async throws -> MessageQuoteResponse
    public var getAttachment:
        @Sendable (_ messageId: UUID, _ attachmentId: UUID) async throws -> (
            data: Data, contentType: String?, suggestedFilename: String?
        )
    public var createOutbox:
        @Sendable (OutboxCreateRequest, [MVOutboxAttachmentUpload]) async throws -> MVOutboxCreateResult
    public var recovery: ComposeRecoveryStore?

    public init(
        listAccounts: @escaping @Sendable () async throws -> [AccountResponse],
        listIdentities: @escaping @Sendable () async throws -> [IdentityResponse],
        getMessage: @escaping @Sendable (UUID) async throws -> MessageDetail,
        getQuote: @escaping @Sendable (UUID) async throws -> MessageQuoteResponse,
        getAttachment:
            @escaping @Sendable (UUID, UUID) async throws -> (
                data: Data, contentType: String?, suggestedFilename: String?
            ),
        createOutbox:
            @escaping @Sendable (OutboxCreateRequest, [MVOutboxAttachmentUpload]) async throws ->
            MVOutboxCreateResult,
        recovery: ComposeRecoveryStore?
    ) {
        self.listAccounts = listAccounts
        self.listIdentities = listIdentities
        self.getMessage = getMessage
        self.getQuote = getQuote
        self.getAttachment = getAttachment
        self.createOutbox = createOutbox
        self.recovery = recovery
    }

    public static func live(client: MVApiClient, recovery: ComposeRecoveryStore?) -> ComposerDependencies {
        ComposerDependencies(
            listAccounts: { try await client.listAccounts() },
            listIdentities: { try await client.listIdentities() },
            getMessage: { try await client.getMessage(id: $0) },
            getQuote: { try await client.getMessageQuote(id: $0) },
            getAttachment: { try await client.getAttachment(messageId: $0, attachmentId: $1) },
            createOutbox: { try await client.createOutbox($0, attachments: $1) },
            recovery: recovery)
    }
}

/// One composer's state, from the intent that opened it to the submit that closes it: new
/// message, reply, reply all, forward, reopened draft, `mailto:` link, or a cancelled send given
/// back. The body itself lives in the editor; the editor reports every change here as a
/// `ComposeDocument`, which is what the dirty check, recovery and submission read.
@Observable
@MainActor
public final class ComposerStore {

    public enum Phase: Equatable, Sendable {
        case loading, editing, sending
        case loadFailed(String)
    }

    public enum SubmitOutcome: Equatable, Sendable {
        case sent
        case draftSaved
        /// Held inside the undo window — the undo-send capsule reports it, not a toast.
        case pending(PendingSendResponse)
        case failed(String)
        /// Refused before anything was sent: no recipient, or an address that is not one.
        case blocked
        /// A second submit while one is in flight, or after one succeeded.
        case ignored
    }

    public let intent: ComposeIntent
    public private(set) var phase: Phase = .loading

    public private(set) var recipients: [ComposeRecipientField: [String]] = [:]
    /// Text typed into a recipient field and not yet a recipient.
    public private(set) var recipientText: [ComposeRecipientField: String] = [:]
    /// "Not a valid email address: …" for text a field could not turn into a recipient.
    public private(set) var recipientNotes: [ComposeRecipientField: String] = [:]
    public var subject = ""
    public var showsCcBcc = false
    public private(set) var fromOptions: [ComposeFromAddress] = []
    public var selectedFromKey: String?
    public private(set) var accounts: [AccountResponse] = []
    public private(set) var attachments: [ComposeAttachment] = []
    public private(set) var inlineImages: [String: ComposeInlineImage] = [:]
    public private(set) var quote: ComposeQuote?
    public private(set) var document: ComposeDocument = .empty
    /// Bumped whenever the store replaces the body wholesale (load, restore) — the editor reloads
    /// its text when this changes, and never otherwise.
    public private(set) var documentRevision = 0
    public private(set) var submitError: String?
    public private(set) var sendHint: String?
    /// Files a reopened composer should have carried and could not get back.
    public private(set) var unrestoredAttachments: [String] = []
    /// A crash-recovery snapshot for this same composer, offered until restored or dismissed.
    public private(set) var recoverable: ComposeRecoveryContent?

    public private(set) var quotedText = ""
    public private(set) var inReplyTo: String?
    public private(set) var references: [String]?
    public private(set) var replacesMessageId: UUID?

    private var baseline = Snapshot()
    /// Set by a restore: restored content can match this composer's own starting fields exactly
    /// and still exist nowhere durable.
    private var holdsUnsavedRestore = false
    private var submitting = false
    private var completed = false
    // One per kind for the composer's lifetime: the server answers a repeat of either with the row
    // the first one created, and a draft save and a send are never the same request.
    private let sendIdempotencyKey = UUID()
    private let draftIdempotencyKey = UUID()
    private let dependencies: ComposerDependencies
    private let undoRestoration: UndoSendRestoration?
    private let preferredAccountId: UUID?

    private struct Snapshot: Equatable {
        var recipients: [ComposeRecipientField: [String]] = [:]
        var subject = ""
        var document = ComposeDocument.empty
        var attachmentIds: [UUID] = []
        var quote: ComposeQuote?
    }

    /// `preferredAccountId` is the account a fresh message defaults to when its intent names
    /// none — the list the person was reading.
    public init(
        intent: ComposeIntent, dependencies: ComposerDependencies, undoRestoration: UndoSendRestoration? = nil,
        preferredAccountId: UUID? = nil
    ) {
        self.intent = intent
        self.dependencies = dependencies
        self.undoRestoration = undoRestoration
        self.preferredAccountId = preferredAccountId
    }

    // MARK: - Derived

    public func recipients(_ field: ComposeRecipientField) -> [String] { recipients[field] ?? [] }

    public var selectedFrom: ComposeFromAddress? {
        fromOptions.first { $0.key == selectedFromKey } ?? fromOptions.first
    }

    public var accountId: UUID? { selectedFrom?.accountId }

    /// The From control only exists when there is a choice to make.
    public var showsFromPicker: Bool { fromOptions.count > 1 }

    public var title: String {
        if case .draft = intent.kind { return "Draft" }
        let trimmed = subject.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "New Message" : trimmed
    }

    public var isDirty: Bool {
        guard !completed, phase == .editing || phase == .sending else { return false }
        return holdsUnsavedRestore || currentSnapshot() != baseline
    }

    public var recoveryKey: String {
        ComposeRecoveryStore.key(replacesMessageId: replacesMessageId, inReplyTo: inReplyTo)
    }

    public func accountName(for accountId: UUID) -> String? {
        accounts.first { $0.id == accountId }?.name
    }

    private func currentSnapshot() -> Snapshot {
        Snapshot(
            recipients: recipients.filter { !$0.value.isEmpty }, subject: subject, document: document,
            attachmentIds: attachments.map(\.id), quote: quote)
    }

    // MARK: - Loading

    public func load() async {
        phase = .loading
        do {
            async let accountsResult = dependencies.listAccounts()
            async let identitiesResult = dependencies.listIdentities()
            let (accounts, identities) = try await (accountsResult, identitiesResult)
            self.accounts = accounts
            try await apply(intent.kind, accounts: accounts, identities: identities)
            showsCcBcc = !recipients(.cc).isEmpty || !recipients(.bcc).isEmpty
            baseline = currentSnapshot()
            recoverable = dependencies.recovery?.read(key: recoveryKey)
            documentRevision += 1
            phase = .editing
        } catch {
            phase = .loadFailed(error.mvUserMessage)
        }
    }

    private func apply(
        _ kind: ComposeIntent.Kind, accounts: [AccountResponse], identities: [IdentityResponse]
    ) async throws {
        let everyAddress = ComposeIdentityRules.pickableAddresses(accounts: accounts, identities: identities)
        switch kind {
        case .new(let accountId):
            fromOptions = everyAddress
            selectedFromKey =
                ComposeIdentityRules.resolve(
                    in: everyAddress, preferring: [accountId, preferredAccountId, accounts.first?.id])?.key
        case .mailto(let link):
            fromOptions = everyAddress
            selectedFromKey = ComposeIdentityRules.resolve(in: everyAddress, preferring: [preferredAccountId])?.key
            recipients = [.to: link.to, .cc: link.cc, .bcc: link.bcc]
            subject = link.subject ?? ""
            if let body = link.bodyHtml { loadBody(body) }
        case .reply(let messageId):
            try await loadReply(messageId, mode: .reply, everyAddress: everyAddress, identities: identities)
        case .replyAll(let messageId):
            try await loadReply(messageId, mode: .replyAll, everyAddress: everyAddress, identities: identities)
        case .forward(let messageId):
            try await loadForward(messageId, everyAddress: everyAddress, identities: identities)
        case .draft(let messageId):
            try await loadDraft(messageId, everyAddress: everyAddress, identities: identities)
        case .undoRestore:
            try applyRestoration(everyAddress: everyAddress, identities: identities)
        }
    }

    private func loadReply(
        _ messageId: UUID, mode: ComposeReplyMode, everyAddress: [ComposeFromAddress], identities: [IdentityResponse]
    ) async throws {
        async let messageResult = dependencies.getMessage(messageId)
        async let quoteResult = dependencies.getQuote(messageId)
        let (message, quoteResponse) = try await (messageResult, quoteResult)
        let accountIdentities = identities.filter { $0.accountId == message.accountId }
        let ownAddresses =
            accounts.filter { $0.id == message.accountId }.map(\.imapUser) + accountIdentities.map(\.address)
        let draft = ComposeReply.reply(to: message, ownAddresses: ownAddresses, mode: mode)
        recipients = [.to: draft.to, .cc: draft.cc]
        subject = draft.subject
        quote = ComposeQuote(html: quoteResponse.html, attribution: draft.attribution)
        quotedText = draft.quotedText
        inReplyTo = draft.inReplyTo
        references = draft.references
        scopeFrom(
            to: message.accountId, everyAddress: everyAddress,
            matched: ComposeIdentityRules.matchIdentity(
                (message.toAddrs?.addresses ?? []) + (message.ccAddrs?.addresses ?? []), in: accountIdentities))
    }

    /// The original's attachments come along; one that cannot be downloaded is named rather than
    /// silently missing.
    private func loadForward(
        _ messageId: UUID, everyAddress: [ComposeFromAddress], identities: [IdentityResponse]
    ) async throws {
        async let messageResult = dependencies.getMessage(messageId)
        async let quoteResult = dependencies.getQuote(messageId)
        let (message, quoteResponse) = try await (messageResult, quoteResult)
        let forward = ComposeReply.forward(message)
        subject = forward.subject
        quote = ComposeQuote(html: quoteResponse.html, attribution: forward.attribution)
        quotedText = forward.quotedText

        var carried: [ComposeAttachment] = []
        var missing: [String] = []
        for attachment in message.attachments {
            let name = attachment.filename ?? "attachment"
            do {
                let download = try await dependencies.getAttachment(message.id, attachment.id)
                carried.append(
                    ComposeAttachment(
                        filename: name, contentType: attachment.contentType ?? download.contentType, data: download.data
                    ))
            } catch {
                missing.append(name)
            }
        }
        attachments = carried
        unrestoredAttachments = missing

        let accountIdentities = identities.filter { $0.accountId == message.accountId }
        scopeFrom(
            to: message.accountId, everyAddress: everyAddress,
            matched: ComposeIdentityRules.matchIdentity(
                (message.toAddrs?.addresses ?? []) + (message.ccAddrs?.addresses ?? []), in: accountIdentities))
    }

    /// A draft's body is read from the quote endpoint, not `body_html`: that copy is shaped for
    /// display, with `cid:` images rewritten to local URLs that mean nothing in a message sent
    /// again. Its own quote is split back out into the quote card.
    private func loadDraft(
        _ messageId: UUID, everyAddress: [ComposeFromAddress], identities: [IdentityResponse]
    ) async throws {
        async let messageResult = dependencies.getMessage(messageId)
        async let quoteResult = dependencies.getQuote(messageId)
        let (message, quoteResponse) = try await (messageResult, quoteResult)
        let split = ComposeQuoteSplitter.split(quoteResponse.html)
        loadBody(split.body)
        quote = split.quote
        quotedText =
            split.quote.map { ComposeReply.draftQuotedText(bodyText: message.bodyText, attribution: $0.attribution) }
            ?? ""
        recipients = [
            .to: message.toAddrs?.addresses ?? [], .cc: message.ccAddrs?.addresses ?? [],
            .bcc: message.bccAddrs?.addresses ?? [],
        ]
        subject = message.subject ?? ""
        inReplyTo = message.inReplyTo
        references = message.references
        replacesMessageId = message.id
        let accountIdentities = identities.filter { $0.accountId == message.accountId }
        scopeFrom(
            to: message.accountId, everyAddress: everyAddress,
            matched: ComposeIdentityRules.matchIdentity([message.fromAddr], in: accountIdentities))
    }

    /// Everything the cancelled send staged comes back — pasted images into the body, other files
    /// as chips, threading headers and the draft it replaces. It counts as unsaved from the
    /// start: the staged row is gone, so this composer is the only copy left.
    private func applyRestoration(everyAddress: [ComposeFromAddress], identities: [IdentityResponse]) throws {
        guard let restoration = undoRestoration else { throw ComposerError.nothingToRestore }
        let row = restoration.row
        recipients = [.to: row.to, .cc: row.cc ?? [], .bcc: row.bcc ?? []]
        subject = row.subject ?? ""
        for image in restoration.inlineImages { inlineImages[image.contentId] = image }
        let split = ComposeQuoteSplitter.split(row.bodyHtml ?? "")
        loadBody(split.body)
        quote = split.quote
        quotedText = split.quote.map(ComposeReply.quotedPlainText(from:)) ?? ""
        attachments = restoration.attachments
        unrestoredAttachments = restoration.missing
        inReplyTo = row.inReplyTo
        references = row.references
        replacesMessageId = row.replacesMessageId
        let accountIdentities = identities.filter { $0.accountId == row.accountId }
        scopeFrom(
            to: row.accountId, everyAddress: everyAddress,
            matched: ComposeIdentityRules.matchIdentity([row.fromAddr], in: accountIdentities))
        holdsUnsavedRestore = true
    }

    /// A reply, forward, draft or restore sends from the account it belongs to, as whichever of
    /// that account's identities the message was addressed to.
    private func scopeFrom(to accountId: UUID, everyAddress: [ComposeFromAddress], matched identityId: UUID?) {
        fromOptions = everyAddress.filter { $0.accountId == accountId }
        selectedFromKey =
            identityId.map(\.uuidString)
            ?? ComposeIdentityRules.defaultAddress(in: fromOptions, accountId: accountId)?.key
    }

    private func loadBody(_ html: String) {
        let parsed = ComposeHTMLParser.parse(html)
        document = parsed.document
        for image in parsed.images { inlineImages[image.contentId] = image }
    }

    // MARK: - Editing

    public func editorDidChange(_ document: ComposeDocument) {
        self.document = document
    }

    /// A comma or semicolon — typed or pasted — commits what came before it.
    public func updateRecipientText(_ text: String, for field: ComposeRecipientField) {
        recipientText[field] = text
        if text.contains(",") || text.contains(";") { commitRecipientText(field) }
    }

    /// Turns the field's text into recipients; whatever is not an address stays in the field with
    /// a note saying so.
    public func commitRecipientText(_ field: ComposeRecipientField) {
        let text = recipientText[field] ?? ""
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            recipientText[field] = ""
            recipientNotes[field] = nil
            return
        }
        let result = ComposeRecipients.commit(text, into: recipients(field))
        recipients[field] = result.recipients
        recipientText[field] = result.invalid.joined(separator: ", ")
        recipientNotes[field] = ComposeRecipients.invalidNote(result.invalid)
        if field == .to, !result.recipients.isEmpty { sendHint = nil }
    }

    /// An autocomplete pick replaces whatever was typed to find it.
    public func addRecipient(_ address: String, to field: ComposeRecipientField) {
        let existing = recipients(field)
        if !existing.contains(where: { $0.caseInsensitiveCompare(address) == .orderedSame }) {
            recipients[field] = existing + [address]
        }
        recipientText[field] = ""
        recipientNotes[field] = nil
        if field == .to { sendHint = nil }
    }

    public func removeRecipient(_ address: String, from field: ComposeRecipientField) {
        recipients[field] = recipients(field).filter { $0 != address }
    }

    public func addAttachments(_ new: [ComposeAttachment]) {
        attachments.append(contentsOf: new)
    }

    public func removeAttachment(id: UUID) {
        attachments.removeAll { $0.id == id }
    }

    /// Registers a pasted image; the editor inserts the returned reference.
    public func addInlineImage(data: Data, filename: String, contentType: String?) -> ComposeImageRef {
        let contentId = ComposeContentId.make()
        inlineImages[contentId] = ComposeInlineImage(
            contentId: contentId, filename: filename, contentType: contentType, data: data)
        return ComposeImageRef(contentId: contentId)
    }

    /// Images a pasted HTML fragment carried as `data:` URIs, already given content ids.
    public func registerInlineImages(_ images: [ComposeInlineImage]) {
        for image in images { inlineImages[image.contentId] = image }
    }

    public func removeQuote() {
        quote = nil
        quotedText = ""
    }

    // MARK: - Submitting

    /// Send or Save Draft. The guard is synchronous — checked and set before the first suspension
    /// point — so a second tap reaching this before the first request returns does nothing.
    @discardableResult
    public func submit(_ kind: OutboxCreateRequest.Kind) async -> SubmitOutcome {
        guard !submitting, !completed, phase == .editing else { return .ignored }
        for field in ComposeRecipientField.allCases { commitRecipientText(field) }
        if kind == .send {
            guard recipientNotes.isEmpty else { return .blocked }
            guard !recipients(.to).isEmpty else {
                sendHint = "Add at least one recipient"
                return .blocked
            }
        }
        guard let from = selectedFrom else {
            submitError = "Add an account before composing a message."
            return .blocked
        }

        submitting = true
        submitError = nil
        if kind == .send { phase = .sending }
        let built = ComposeSubmission.build(
            ComposeSubmissionInput(
                accountId: from.accountId, kind: kind, to: recipients(.to), cc: recipients(.cc), bcc: recipients(.bcc),
                subject: subject, document: document, quote: quote, quotedText: quotedText, inReplyTo: inReplyTo,
                references: references, identityId: from.identityId, replacesMessageId: replacesMessageId,
                attachments: attachments, inlineImages: inlineImages,
                idempotencyKey: kind == .send ? sendIdempotencyKey : draftIdempotencyKey))
        do {
            let result = try await dependencies.createOutbox(built.request, built.uploads)
            completed = true
            dependencies.recovery?.clear(key: recoveryKey)
            switch result {
            case .pending(let row): return .pending(row)
            case .sent: return kind == .send ? .sent : .draftSaved
            }
        } catch {
            submitting = false
            phase = .editing
            let message = "\(kind == .send ? "Not sent" : "Not saved"): \(error.mvUserMessage)"
            submitError = message
            return .failed(message)
        }
    }

    /// A deliberate discard — the one way out that sends nothing and keeps nothing.
    public func discard() {
        dependencies.recovery?.clear(key: recoveryKey)
        completed = true
    }

    // MARK: - Crash recovery

    /// Called every second while editing and when the app goes to the background; writes only
    /// while there is something unsaved.
    public func saveRecoverySnapshot() {
        guard isDirty, let recovery = dependencies.recovery else { return }
        try? recovery.write(recoveryContent, key: recoveryKey)
    }

    public var recoveryContent: ComposeRecoveryContent {
        ComposeRecoveryContent(
            to: recipients(.to), cc: recipients(.cc), bcc: recipients(.bcc), subject: subject, document: document,
            quote: quote, attachments: attachments,
            inlineImages: document.referencedContentIds.compactMap { inlineImages[$0] })
    }

    public func restoreRecovered() {
        guard let content = recoverable else { return }
        recipients = [.to: content.to, .cc: content.cc, .bcc: content.bcc]
        subject = content.subject
        document = content.document
        if content.quote != quote {
            quote = content.quote
            quotedText = content.quote.map(ComposeReply.quotedPlainText(from:)) ?? ""
        }
        attachments = content.attachments
        for image in content.inlineImages { inlineImages[image.contentId] = image }
        showsCcBcc = showsCcBcc || !content.cc.isEmpty || !content.bcc.isEmpty
        holdsUnsavedRestore = true
        recoverable = nil
        documentRevision += 1
    }

    public func dismissRecovered() {
        recoverable = nil
    }

    // MARK: - Debug

    public struct DebugState: Encodable, Sendable {
        public let phase: String
        public let dirty: Bool
        public let title: String
        public let to: [String]
        public let cc: [String]
        public let bcc: [String]
        public let subject: String
        public let from: String?
        public let attachmentCount: Int
        public let inlineImageCount: Int
        public let hasQuote: Bool
        public let documentBlockCount: Int
    }

    public var debugState: DebugState {
        DebugState(
            phase: "\(phase)", dirty: isDirty, title: title, to: recipients(.to), cc: recipients(.cc),
            bcc: recipients(.bcc), subject: subject, from: selectedFrom?.label, attachmentCount: attachments.count,
            inlineImageCount: document.referencedContentIds.count, hasQuote: quote != nil,
            documentBlockCount: document.blocks.count)
    }
}

enum ComposerError: LocalizedError {
    case nothingToRestore

    var errorDescription: String? {
        switch self {
        case .nothingToRestore: return "The cancelled message could not be found."
        }
    }
}
