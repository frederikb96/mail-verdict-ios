import Foundation
import Observation

/// What a page slot shows for one row.
public enum ReaderPageState: Sendable, Equatable {
    case loading
    case loaded(ReaderConversation)
    case failed(String)
}

/// A change a page applies to its web view.
public enum ReaderPageUpdate: Sendable, Equatable {
    /// A whole new document. `revealsOpened` scrolls the opened message to the top once it loads.
    case document(html: String, revealsOpened: Bool)
    /// The conversation gained or lost messages, or the theme changed: the page notes its reading
    /// position and which messages are expanded, asks `rebuiltDocument(for:expandedElementIds:)`
    /// for the new document, and puts the position back.
    case rebuild
    /// One block swapped in place — scroll, zoom and find all survive.
    case replaceBlock(elementId: String, html: String)
}

/// What the screen does after an action on the current message.
public enum ReaderActionOutcome: Sendable, Equatable {
    case stay
    case advance(to: UUID, direction: MVAutoAdvanceDirection)
    case close
}

/// Everything behind a reader screen that is not a view: the conversation per page, the
/// reference data, the per-message canvas choices and invitation cards, the rules that run when a
/// page settles, every message action, and live updates.
@Observable
@MainActor
public final class ReaderSession {
    public let context: ReaderContext
    public let paging: ReaderPagingStore
    public private(set) var pages: [UUID: ReaderPageState] = [:]
    public private(set) var theme: MVCanvas
    /// Changes whenever something the Options menu or the bars read changes — read and star
    /// state, a folder's role, a canvas.
    public private(set) var revision = 0

    @ObservationIgnored public var onPageUpdate: (@MainActor (_ rowId: UUID, ReaderPageUpdate) -> Void)?
    @ObservationIgnored public var onToast: (@MainActor (MVToast) -> Void)?
    /// The list dropped the current row, or it no longer exists — the pager slides on or closes.
    @ObservationIgnored public var onCurrentRemoved: (@MainActor (ReaderRemoval) -> Void)?

    @ObservationIgnored public let api: MVApiClient
    @ObservationIgnored public let lookups: ReaderLookups
    /// The app's one \"where is this message now\" resolver — shared, so Show in Folder answers from
    /// the same unified-view membership the rest of the app uses.
    @ObservationIgnored private let placeResolver: MVMessagePlaceResolver
    @ObservationIgnored private weak var source: (any ReaderListSource)?
    @ObservationIgnored private let registry: ReaderSourceRegistry
    @ObservationIgnored private let tracker: MVExplicitUnreadTracker
    @ObservationIgnored private let canvasStore: MVCanvasPreferenceStore
    @ObservationIgnored private var canvasChoices: MVCanvasChoices
    @ObservationIgnored private var canvases: [UUID: MVCanvas] = [:]
    @ObservationIgnored private var folderRoles: [UUID: String] = [:]
    @ObservationIgnored private var avatarSources: [UUID: [String: String]] = [:]
    @ObservationIgnored private var invitations: [UUID: InvitationStore] = [:]
    @ObservationIgnored private var loadTasks: [UUID: Task<Void, Never>] = [:]
    @ObservationIgnored private var settledRowId: UUID?
    @ObservationIgnored private var readRulesApplied: Set<UUID> = []
    /// Pages drawn from a cached copy whose revalidation has not answered yet. Their read rules
    /// wait for it: the copy can say read when the message is not.
    @ObservationIgnored private var awaitingRevalidation: Set<UUID> = []
    @ObservationIgnored private let cacheDirectory: URL
    /// Conversations fetched ahead of the reader (`MVThreadCache`): a page with a recent copy is
    /// drawn from it at once and revalidated behind it.
    @ObservationIgnored private let threadCache: MVThreadCache?

    public init(
        context: ReaderContext, api: MVApiClient, placeResolver: MVMessagePlaceResolver, theme: MVCanvas,
        registry: ReaderSourceRegistry = .shared,
        tracker: MVExplicitUnreadTracker = .shared, canvasStore: MVCanvasPreferenceStore = MVCanvasPreferenceStore(),
        cacheDirectory: URL = FileManager.default.temporaryDirectory, threadCache: MVThreadCache? = nil,
        referenceCache: MVReferenceCache? = nil
    ) {
        self.context = context
        self.api = api
        self.placeResolver = placeResolver
        self.theme = theme
        self.registry = registry
        self.tracker = tracker
        self.canvasStore = canvasStore
        self.canvasChoices = canvasStore.load()
        self.threadCache = threadCache
        self.lookups = ReaderLookups(api: api, cache: referenceCache)
        self.cacheDirectory = cacheDirectory.appendingPathComponent("attachments", isDirectory: true)
        let source = registry.source(for: context.source)
        self.source = source
        self.paging = ReaderPagingStore(openedId: context.messageId, source: source)
        paging.onCurrentRemovedExternally = { [weak self] removal in
            self?.onCurrentRemoved?(removal)
        }
        paging.startObservingSource()
    }

    // MARK: Reading state

    public var title: String? {
        source?.readerTitle
    }

    public var currentRowId: UUID { paging.currentId }

    public func conversation(for rowId: UUID) -> ReaderConversation? {
        if case .loaded(let conversation) = pages[rowId] { return conversation }
        return nil
    }

    public var currentPrimary: MessageDetail? {
        conversation(for: currentRowId)?.primary
    }

    public func folderRole(of message: MessageDetail) -> String? {
        folderRoles[message.folderId]
    }

    public var isCurrentInArchive: Bool {
        currentPrimary.map { folderRole(of: $0) == "archive" } ?? false
    }

    public var isCurrentInTrash: Bool {
        currentPrimary.map { folderRole(of: $0) == "trash" } ?? false
    }

    /// The Options menu's input for the current message, or `nil` until it has loaded.
    public func optionsContext() -> MVMessageContext? {
        guard let message = currentPrimary else { return nil }
        let role = folderRole(of: message)
        let actionSource: MVMessageActionSource
        switch context.source {
        case .list: actionSource = .list
        case .search: actionSource = .search
        case .spamReview: actionSource = .spamReview
        }
        return MVMessageContext(
            surface: .readerOptionsMenu, source: actionSource, isRead: message.isSeen, isStarred: message.isFlagged,
            isInTrash: role == "trash", isInJunk: role == "junk",
            verdict: message.verdict.map { MVMessageVerdictContext(isSpam: $0.isSpam, modelUsed: $0.modelUsed) },
            hasBlockedImages: !message.isTruncated && message.hasBlockedImages && !message.imagesAllowed,
            canvasIsDark: canvases[message.id] == .dark)
    }

    /// Whether a page may show remote images at all — the content rule list it loads under.
    public func imagesAllowed(for rowId: UUID) -> Bool {
        conversation(for: rowId)?.messages.contains { $0.imagesAllowed } ?? false
    }

    /// Whether the current message's body is HTML — the canvas toggle only applies then.
    public var currentHasHTMLBody: Bool {
        currentPrimary.map { !($0.bodyHtml ?? "").isEmpty && !$0.isTruncated } ?? false
    }

    // MARK: Pages

    /// The document a slot shows for a row right now; starts loading the row when needed.
    public func document(for rowId: UUID) -> (html: String, revealsOpened: Bool) {
        ensureLoaded(rowId)
        switch pages[rowId] {
        case .loaded(let conversation):
            return (ConversationDocumentBuilder.document(for: conversation, options: options(for: rowId)), true)
        case .failed(let message):
            return (ConversationDocumentBuilder.errorDocument(message: message, theme: theme), false)
        case .loading, nil:
            return (ConversationDocumentBuilder.loadingDocument(theme: theme), false)
        }
    }

    public func rebuiltDocument(for rowId: UUID, expandedElementIds: [String]) -> String {
        guard let conversation = conversation(for: rowId) else { return document(for: rowId).html }
        let open = Set(expandedElementIds)
        var options = options(for: rowId)
        let expanded = conversation.messages.filter {
            open.contains(ConversationDocumentBuilder.messageElementId($0.id))
        }
        options.expandedIds = expanded.isEmpty ? nil : Set(expanded.map(\.id))
        return ConversationDocumentBuilder.document(for: conversation, options: options)
    }

    /// Starts loading `rowId` unless it already is. A recent copy in the thread cache, with the
    /// folders and photos it needs also cached, is drawn in the same call — the page's first
    /// document is then the conversation itself rather than a loading placeholder — and
    /// revalidated behind it.
    public func ensureLoaded(_ rowId: UUID) {
        guard pages[rowId] == nil else { return }
        if let cached = threadCache?.cached(rowId), !cached.messages.isEmpty,
            applyReferenceDataIfCached(for: cached.messages, rowId: rowId)
        {
            awaitingRevalidation.insert(rowId)
            show(cached, for: rowId)
            refresh(rowId) { [weak self] in
                guard let self, self.awaitingRevalidation.remove(rowId) != nil else { return }
                if rowId == self.settledRowId { self.applyReadRules(rowId) }
            }
            return
        }
        load(rowId)
    }

    public func retry(_ rowId: UUID) {
        pages[rowId] = nil
        ensureLoaded(rowId)
        emit(rowId, .document(html: ConversationDocumentBuilder.loadingDocument(theme: theme), revealsOpened: false))
    }

    public func setTheme(_ newTheme: MVCanvas) {
        guard newTheme != theme else { return }
        theme = newTheme
        canvases = [:]
        for rowId in pages.keys {
            emit(
                rowId,
                conversation(for: rowId) != nil
                    ? .rebuild : .document(html: document(for: rowId).html, revealsOpened: false))
        }
    }

    private func load(_ rowId: UUID) {
        pages[rowId] = .loading
        loadTasks[rowId]?.cancel()
        loadTasks[rowId] = Task { [weak self] in
            guard let self else { return }
            do {
                let thread = try await self.fetchThread(rowId)
                guard !Task.isCancelled else { return }
                await self.apply(thread, to: rowId)
            } catch {
                guard !Task.isCancelled else { return }
                self.loadFailed(rowId, error: error)
            }
        }
    }

    /// Through the thread cache when there is one, joining a prefetch already in flight and
    /// keeping the answer for the next open.
    private func fetchThread(_ rowId: UUID) async throws -> ThreadResponse {
        guard let threadCache else { return try await api.getThread(messageId: rowId) }
        return try await threadCache.thread(for: rowId)
    }

    private func apply(_ thread: ThreadResponse, to rowId: UUID) async {
        guard !thread.messages.isEmpty else {
            loadFailed(rowId, error: MVError.http(statusCode: 404, reason: "Not Found"))
            return
        }
        await prepareReferenceData(for: thread.messages, rowId: rowId)
        guard pages[rowId] != nil else { return }
        show(thread, for: rowId)
    }

    private func show(_ thread: ThreadResponse, for rowId: UUID) {
        let conversation = ReaderConversation(messages: thread.messages, openedId: rowId)
        pages[rowId] = .loaded(conversation)
        revision += 1
        emit(
            rowId,
            .document(
                html: ConversationDocumentBuilder.document(for: conversation, options: options(for: rowId)),
                revealsOpened: true))
        loadInvitations(for: conversation, rowId: rowId)
        if rowId == settledRowId { applyReadRules(rowId) }
    }

    private func loadFailed(_ rowId: UUID, error: Error) {
        if Self.isNotFound(error) {
            pages[rowId] = .failed("That message no longer exists")
            if rowId == currentRowId {
                onToast?(MVToast(variant: .info, message: "That message no longer exists"))
                if let removal = paging.remove(rowId) { onCurrentRemoved?(removal) }
            } else {
                _ = paging.remove(rowId)
            }
        } else {
            pages[rowId] = .failed(error.mvUserMessage)
        }
        emit(rowId, .document(html: document(for: rowId).html, revealsOpened: false))
    }

    /// Folder roles and sender photos, fetched before the first document so it already carries
    /// the right Delete/Junk labels and avatars rather than redrawing a moment later.
    private func prepareReferenceData(for messages: [MessageDetail], rowId: UUID) async {
        var folders: [UUID: [FolderResponse]] = [:]
        var indexes: [UUID: ContactPhotoIndexResponse] = [:]
        for accountId in Set(messages.map(\.accountId)) {
            async let accountFolders = lookups.folders(accountId: accountId)
            async let index = lookups.photoIndex(accountId: accountId)
            folders[accountId] = await accountFolders
            indexes[accountId] = await index
        }
        applyReferenceData(folders: folders, indexes: indexes, messages: messages, rowId: rowId)
    }

    /// The synchronous half of `prepareReferenceData`: `false`, changing nothing, unless every
    /// account's folders and photo index are already cached.
    private func applyReferenceDataIfCached(for messages: [MessageDetail], rowId: UUID) -> Bool {
        var folders: [UUID: [FolderResponse]] = [:]
        var indexes: [UUID: ContactPhotoIndexResponse] = [:]
        for accountId in Set(messages.map(\.accountId)) {
            guard let accountFolders = lookups.cachedFolders(accountId: accountId),
                let index = lookups.cachedPhotoIndex(accountId: accountId)
            else { return false }
            folders[accountId] = accountFolders
            indexes[accountId] = index
        }
        applyReferenceData(folders: folders, indexes: indexes, messages: messages, rowId: rowId)
        return true
    }

    private func applyReferenceData(
        folders: [UUID: [FolderResponse]], indexes: [UUID: ContactPhotoIndexResponse], messages: [MessageDetail],
        rowId: UUID
    ) {
        for folder in folders.values.joined() {
            if let role = folder.specialUse { folderRoles[folder.id] = role }
        }
        var sources: [String: String] = [:]
        for message in messages {
            let email = extractEmail(message.fromAddr).lowercased()
            if let src = ReaderLookups.avatarSource(
                for: email, in: indexes[message.accountId], imagesAllowed: message.imagesAllowed)
            {
                sources[email] = src
            }
        }
        avatarSources[rowId] = sources
    }

    private func options(for rowId: UUID) -> ReaderDocumentOptions {
        var options = ReaderDocumentOptions(
            theme: theme, avatarSources: avatarSources[rowId] ?? [:], now: Date())
        if let conversation = conversation(for: rowId) {
            for message in conversation.messages {
                if let choice = canvasChoices.choice(for: message.id) { options.canvasChoices[message.id] = choice }
                if let card = invitations[message.id], card.model != nil {
                    options.invitationCards[message.id] = card.slotHTML
                }
                canvases[message.id] = ConversationDocumentBuilder.rendering(for: message, options: options).canvas
            }
        }
        return options
    }

    private func emit(_ rowId: UUID, _ update: ReaderPageUpdate) {
        onPageUpdate?(rowId, update)
    }

    // MARK: Settling

    /// The pager came to rest on `rowId` — the only moment reading counts: a neighbour loaded in
    /// the background is never marked read.
    public func didSettle(on rowId: UUID) {
        settledRowId = rowId
        registry.recordSettled(rowId, for: context.source)
        ensureLoaded(rowId)
        var keep: Set<UUID> = [rowId]
        for case .message(let id)? in [paging.older, paging.newer] {
            ensureLoaded(id)
            keep.insert(id)
        }
        evictPages(keeping: keep)
        if conversation(for: rowId) != nil { applyReadRules(rowId) }
        Task { [paging] in await paging.loadMoreIfNeeded() }
    }

    private func evictPages(keeping keep: Set<UUID>) {
        for rowId in pages.keys where !keep.contains(rowId) {
            loadTasks[rowId]?.cancel()
            loadTasks[rowId] = nil
            if let conversation = conversation(for: rowId) {
                for message in conversation.messages { invitations[message.id] = nil }
            }
            pages[rowId] = nil
            avatarSources[rowId] = nil
            readRulesApplied.remove(rowId)
            awaitingRevalidation.remove(rowId)
        }
    }

    private func applyReadRules(_ rowId: UUID) {
        guard !readRulesApplied.contains(rowId), !awaitingRevalidation.contains(rowId),
            let conversation = conversation(for: rowId),
            let primary = conversation.primary
        else { return }
        readRulesApplied.insert(rowId)
        let scopedFolders = (source as? any ReaderConversationScopedSource)?.conversationFolderIds(for: rowId)
        Task { [weak self] in
            guard let self else { return }
            let explicit = await self.tracker.isExplicit(primary.id)
            if !explicit { await self.tracker.clear() }
            if ReaderReadPolicy.shouldMarkRead(primary, explicitlyUnreadId: explicit ? primary.id : nil) {
                await self.send(
                    .markRead, to: primary.id, optimistic: { $0.isSeen = true }, revert: { $0.isSeen = false })
            }
            if let scopedFolders {
                let ids = ReaderReadPolicy.conversationIdsToMarkRead(
                    thread: conversation.messages, openedId: primary.id, folderIds: scopedFolders)
                if !ids.isEmpty {
                    for id in ids { self.updateMessage(id) { $0.isSeen = true } }
                    _ = try? await self.api.bulkAction(
                        accountId: primary.accountId, request: BulkActionRequest(action: .markRead, ids: ids))
                }
            }
            if let alerts = try? await self.api.listAlerts(limit: 200, unseenOnly: true) {
                for alert in alerts where alert.messageId == primary.id && alert.dismissedAt == nil {
                    try? await self.api.dismissAlert(id: alert.id)
                }
            }
        }
    }

    // MARK: Actions leaving the list

    /// Archive, Delete, Delete Forever, Junk and Not Junk: the page slides on to the neighbour in
    /// the direction last paged straight away, and the request follows. An undoable action offers
    /// Undo, which moves the message back; a failed one puts it back in the pager.
    public func remove(with action: MVMessageAction) -> ReaderActionOutcome {
        guard let message = currentPrimary else { return .stay }
        let rowId = currentRowId
        let originalFolderId = message.folderId
        let removal = paging.remove(rowId)
        Task { [weak self] in
            guard let self else { return }
            do {
                _ = try await self.api.performMessageAction(messageId: message.id, action: action)
                if let label = MailActionLabels.undoToast(for: action) {
                    self.onToast?(
                        MVToast(
                            variant: .success, message: label, duration: 6, actionTitle: "Undo",
                            action: { [weak self] in
                                Task { @MainActor in
                                    await self?.undoMove(message.id, rowId: rowId, to: originalFolderId)
                                }
                            }))
                }
            } catch {
                self.paging.restore(rowId)
                self.onToast?(
                    MVToast(
                        variant: .error, message: MailActionLabels.failure(action, reason: error.mvUserMessage),
                        duration: 0))
            }
        }
        switch removal {
        case .advance(let target, let direction)?: return .advance(to: target, direction: direction)
        case .exhausted?, nil: return .close
        }
    }

    private func undoMove(_ messageId: UUID, rowId: UUID, to folderId: UUID) async {
        do {
            _ = try await api.performMessageAction(messageId: messageId, action: .move, targetFolderId: folderId)
            paging.restore(rowId)
        } catch {
            onToast?(
                MVToast(
                    variant: .error, message: MailActionLabels.failure(.move, reason: error.mvUserMessage),
                    duration: 0))
        }
    }

    // MARK: Actions on the message

    public func setRead(_ read: Bool) async {
        guard let message = currentPrimary else { return }
        if read {
            if await tracker.isExplicit(message.id) { await tracker.clear() }
        } else {
            await tracker.markExplicit(message.id)
        }
        await send(
            read ? .markRead : .markUnread, to: message.id, optimistic: { $0.isSeen = read },
            revert: { $0.isSeen = !read })
    }

    public func setStarred(_ starred: Bool) async {
        guard let message = currentPrimary else { return }
        await send(
            starred ? .flag : .unflag, to: message.id, optimistic: { $0.isFlagged = starred },
            revert: { $0.isFlagged = !starred })
    }

    public func move(to folderId: UUID) async {
        guard let message = currentPrimary else { return }
        do {
            _ = try await api.performMessageAction(messageId: message.id, action: .move, targetFolderId: folderId)
        } catch {
            onToast?(
                MVToast(
                    variant: .error, message: MailActionLabels.failure(.move, reason: error.mvUserMessage),
                    duration: 0))
        }
    }

    /// 👍 confirms the verdict, 👎 corrects it — one feedback call either way, as on the web. A
    /// ruling can move the message, so the page re-reads its conversation afterwards.
    public func sendVerdictFeedback(confirming: Bool) async {
        guard let message = currentPrimary, let verdict = message.verdict else { return }
        do {
            _ = try await api.submitFeedback(
                messageId: message.id, accountId: message.accountId,
                isSpam: confirming ? verdict.isSpam : !verdict.isSpam)
            refresh(currentRowId)
        } catch {
            onToast?(
                MVToast(variant: .error, message: "Could not send feedback: \(error.mvUserMessage)", duration: 0))
        }
    }

    /// "Load for this message". The server restores remote images only for an allowlisted sender,
    /// so for anyone else the body comes back still stripped — said so, rather than hiding the
    /// banner over a body that never changed.
    public func loadImagesOnce(messageId: UUID) async {
        guard let rowId = row(containing: messageId) else { return }
        do {
            let detail = try await api.getMessage(id: messageId, loadImages: true)
            if detail.hasBlockedImages && !detail.imagesAllowed {
                onToast?(
                    MVToast(
                        variant: .info,
                        message:
                            "This server only loads remote images for allowed senders — choose Always Load from the sender or domain."
                    ))
                return
            }
            replaceMessage(detail, in: rowId)
        } catch {
            onToast?(
                MVToast(variant: .error, message: "Could not load images: \(error.mvUserMessage)", duration: 0))
        }
    }

    public func alwaysLoadImages(messageId: UUID, from choice: MVReaderLink.ImageChoice) async {
        guard let rowId = row(containing: messageId),
            let message = conversation(for: rowId)?.messages.first(where: { $0.id == messageId })
        else { return }
        let email = extractEmail(message.fromAddr)
        let value = choice == .domain ? String(email.split(separator: "@").last ?? "") : email
        guard !value.isEmpty else { return }
        do {
            _ = try await api.createImageException(
                accountId: message.accountId,
                ImageExceptionCreate(type: choice == .domain ? .domain : .sender, value: value))
            for rowId in pages.keys { refresh(rowId) }
        } catch {
            onToast?(
                MVToast(variant: .error, message: "Could not allow images: \(error.mvUserMessage)", duration: 0))
        }
    }

    public func toggleCanvas(messageId: UUID) {
        guard let rowId = row(containing: messageId),
            let message = conversation(for: rowId)?.messages.first(where: { $0.id == messageId })
        else { return }
        let next = (canvases[messageId] ?? theme).toggled
        canvasChoices.set(next, for: messageId)
        canvasStore.save(canvasChoices)
        let rendering = ConversationDocumentBuilder.rendering(for: message, options: options(for: rowId))
        canvases[messageId] = rendering.canvas
        revision += 1
        emit(
            rowId,
            .replaceBlock(
                elementId: ConversationDocumentBuilder.bodyElementId(messageId),
                html: ConversationDocumentBuilder.bodyHost(messageId, rendering: rendering)))
    }

    /// Reply, Reply All and Forward answer the thread's newest message.
    public func composeIntent(for action: MVMessageUIAction) -> ComposeIntent? {
        guard let newest = conversation(for: currentRowId)?.newest else { return nil }
        switch action {
        case .reply: return ComposeIntent(kind: .reply(messageId: newest.id))
        case .replyAll: return ComposeIntent(kind: .replyAll(messageId: newest.id))
        case .forward: return ComposeIntent(kind: .forward(messageId: newest.id))
        default: return nil
        }
    }

    /// "Show in Folder": the list the message lives in now, opened around it.
    public func showInFolderRoute() async -> Route? {
        guard let message = currentPrimary else { return nil }
        switch await placeResolver.resolve(messageId: message.id) {
        case .route(let routes): return routes.first
        case .notFound(let text):
            onToast?(MVToast(variant: .info, message: text))
            return nil
        }
    }

    /// The address a header link names, and every address on the same line — "Copy All To/Cc".
    public func addresses(
        messageId: UUID, field: MVReaderLink.AddressField, index: Int
    ) -> (address: String, line: [String])? {
        guard let rowId = row(containing: messageId),
            let message = conversation(for: rowId)?.messages.first(where: { $0.id == messageId })
        else { return nil }
        let line: [String]
        switch field {
        case .from: line = message.fromAddr.map { [$0] } ?? []
        case .to: line = message.toAddrs?.addresses ?? []
        case .cc: line = message.ccAddrs?.addresses ?? []
        }
        guard index < line.count else { return nil }
        return (extractEmail(line[index]), line.map { extractEmail($0) })
    }

    // MARK: Files

    /// "Share Message File…": the message's raw source as a `.eml` file.
    public func rawMessageFile() async throws -> URL {
        guard let message = currentPrimary else { throw MVError.transport("No message is open") }
        let result = try await api.getRawMessage(id: message.id)
        let name = Self.safeFilename(result.suggestedFilename ?? "\(message.subject ?? "message").eml")
        return try write(result.data, messageId: message.id, name: name.hasSuffix(".eml") ? name : name + ".eml")
    }

    /// An attachment downloaded for QuickLook or the share sheet. Kept only while the reader is
    /// open — `cleanUp()` removes it.
    public func attachmentFile(messageId: UUID, attachmentId: UUID) async throws -> URL {
        let summary = conversation(for: row(containing: messageId) ?? currentRowId)?.messages
            .first { $0.id == messageId }?.attachments.first { $0.id == attachmentId }
        let name = Self.safeFilename(summary?.filename ?? "attachment")
        let url = directory(for: messageId).appendingPathComponent(
            attachmentId.uuidString.lowercased(), isDirectory: true
        )
        .appendingPathComponent(name)
        if FileManager.default.fileExists(atPath: url.path) { return url }
        let result = try await api.getAttachment(messageId: messageId, attachmentId: attachmentId)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try result.data.write(to: url, options: .atomic)
        return url
    }

    /// Removes the downloaded files. Called whenever the reader leaves the screen — another screen
    /// pushed over it included — so a later preview simply downloads again.
    public func cleanUp() {
        try? FileManager.default.removeItem(at: cacheDirectory)
    }

    private func write(_ data: Data, messageId: UUID, name: String) throws -> URL {
        let directory = directory(for: messageId)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent(name)
        try data.write(to: url, options: .atomic)
        return url
    }

    private func directory(for messageId: UUID) -> URL {
        cacheDirectory.appendingPathComponent(messageId.uuidString.lowercased(), isDirectory: true)
    }

    static func safeFilename(_ name: String) -> String {
        let cleaned = name.map { "/\\:\n\r\0".contains($0) ? "_" : $0 }
        let result = String(cleaned).trimmingCharacters(in: .whitespaces)
        return result.isEmpty || result == "." || result == ".." ? "attachment" : result
    }

    // MARK: Invitations

    public func invitationStore(for messageId: UUID) -> InvitationStore? {
        invitations[messageId]
    }

    private func loadInvitations(for conversation: ReaderConversation, rowId: UUID) {
        for message in conversation.messages where ConversationDocumentBuilder.hasCalendarAttachment(message) {
            let store = invitations[message.id] ?? InvitationStore(messageId: message.id, api: api, lookups: lookups)
            invitations[message.id] = store
            store.onChange = { [weak self, weak store] in
                guard let self, let store else { return }
                self.emit(
                    rowId,
                    .replaceBlock(
                        elementId: InvitationCardBuilder.slotId(messageId: store.messageId), html: store.slotHTML))
            }
            Task { await store.load() }
        }
    }

    // MARK: Live updates

    /// The reader's share of the live event stream: a conversation that changed is re-read — in
    /// place when only a message's content changed, rebuilt around the reading position when
    /// messages joined or left it — and invitation cards re-read when the calendar side moved.
    /// Read and star changes never touch the page; they only relabel the Options menu.
    public func handle(_ invalidations: [MVLiveInvalidation]) {
        var rows: Set<UUID> = []
        var invitationsChanged = false
        for invalidation in invalidations {
            switch invalidation {
            case .resync:
                lookups.invalidateFolders()
                rows.formUnion(pages.keys)
            case .mailNew:
                rows.formUnion(pages.keys)
            case .mailUpdated(_, _, let messageId?, _), .mailDeleted(_, _, let messageId?),
                .verdictIssued(_, let messageId?, _):
                rows.formUnion(pages.keys.filter { conversation(for: $0)?.messageIds.contains(messageId) ?? false })
            case .foldersChanged:
                lookups.invalidateFolders()
            case .identitiesChanged:
                lookups.invalidateCalendarData()
            case .invitationOrEventChanged:
                invitationsChanged = true
            default:
                break
            }
        }
        for rowId in rows { refresh(rowId) }
        if invitationsChanged {
            for store in invitations.values { Task { await store.load() } }
        }
    }

    /// Re-reads one page's conversation and applies the difference.
    /// `completion` runs once the answer is applied, or once it is known there is none to apply.
    public func refresh(_ rowId: UUID, then completion: (@MainActor () -> Void)? = nil) {
        guard let previous = conversation(for: rowId) else {
            completion?()
            return
        }
        Task { [weak self] in
            guard let self else { return }
            defer { completion?() }
            guard let thread = try? await self.api.getThread(messageId: rowId) else { return }
            self.threadCache?.store(thread, for: rowId)
            guard let current = self.conversation(for: rowId),
                current == previous || current.messageIds == previous.messageIds
            else { return }
            let next = ReaderConversation(messages: thread.messages, openedId: rowId)
            guard !next.messages.isEmpty else { return }
            if next.messageIds != current.messageIds {
                await self.prepareReferenceData(for: next.messages, rowId: rowId)
                self.pages[rowId] = .loaded(next)
                self.revision += 1
                self.emit(rowId, .rebuild)
                self.loadInvitations(for: next, rowId: rowId)
                return
            }
            for message in next.messages {
                self.replaceMessage(message, in: rowId)
            }
        }
    }

    /// Swaps one message's model, redrawing its content block only when something the page shows
    /// changed — a read or star flip alone leaves the page untouched.
    private func replaceMessage(_ message: MessageDetail, in rowId: UUID) {
        guard var conversation = conversation(for: rowId),
            let index = conversation.messages.firstIndex(where: { $0.id == message.id })
        else { return }
        let old = conversation.messages[index]
        conversation.messages[index] = message
        pages[rowId] = .loaded(conversation)
        revision += 1
        guard Self.pageContentDiffers(old, message) else { return }
        emit(
            rowId,
            .replaceBlock(
                elementId: ConversationDocumentBuilder.contentElementId(message.id),
                html: ConversationDocumentBuilder.content(message, options: options(for: rowId))))
    }

    static func pageContentDiffers(_ lhs: MessageDetail, _ rhs: MessageDetail) -> Bool {
        lhs.bodyHtml != rhs.bodyHtml || lhs.bodyText != rhs.bodyText || lhs.verdict != rhs.verdict
            || lhs.hasBlockedImages != rhs.hasBlockedImages || lhs.imagesAllowed != rhs.imagesAllowed
            || lhs.isTruncated != rhs.isTruncated || lhs.attachments != rhs.attachments
    }

    // MARK: Helpers

    private func send(
        _ action: MVMessageAction, to messageId: UUID, optimistic: (inout MessageDetail) -> Void,
        revert: (inout MessageDetail) -> Void
    ) async {
        updateMessage(messageId, optimistic)
        do {
            _ = try await api.performMessageAction(messageId: messageId, action: action)
        } catch {
            updateMessage(messageId, revert)
            onToast?(
                MVToast(
                    variant: .error, message: MailActionLabels.failure(action, reason: error.mvUserMessage),
                    duration: 0))
        }
    }

    private func updateMessage(_ messageId: UUID, _ change: (inout MessageDetail) -> Void) {
        for rowId in pages.keys {
            guard var conversation = conversation(for: rowId),
                let index = conversation.messages.firstIndex(where: { $0.id == messageId })
            else { continue }
            change(&conversation.messages[index])
            pages[rowId] = .loaded(conversation)
        }
        revision += 1
    }

    private func row(containing messageId: UUID) -> UUID? {
        if conversation(for: currentRowId)?.messageIds.contains(messageId) == true { return currentRowId }
        return pages.keys.first { conversation(for: $0)?.messageIds.contains(messageId) ?? false }
    }

    static func isNotFound(_ error: Error) -> Bool {
        switch error as? MVError {
        case .detail(_, let status)?, .http(let status, _)?: return status == 404
        default: return false
        }
    }
}

extension ReaderSession: LiveEventSubscriber {
    public func apply(_ invalidations: [MVLiveInvalidation]) {
        handle(invalidations)
    }
}
