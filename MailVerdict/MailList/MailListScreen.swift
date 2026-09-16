import MailVerdictKit
import SwiftUI

/// The message list: one folder or unified view, the way Mail shows it. The rows are a UIKit
/// table (`MailListViewController`) for its swipes, context menu, two-finger selection and exact
/// scroll anchoring; everything around them — bars, filters, sheets, confirmations — is here.
struct MailListScreen: View {
    let scope: ListScope
    let aroundMessageId: UUID?
    let environment: AppEnvironment
    let connection: AppEnvironment.Connection

    @State private var store: MVMailListStore
    @State private var proxy = MailListControllerProxy()
    @State private var liveToken: MVSubscriptionToken?
    @State private var now = Date()
    @State private var searchText = ""
    @State private var optionsRow: MessageSummary?
    @State private var pendingOptionsAction: PendingRowAction?
    @State private var movePicker: MovePickerRequest?
    @State private var pendingMove: PendingMove?
    @State private var deleteForeverRow: MessageSummary?
    @State private var bulkConfirmation: BulkConfirmation?
    @State private var emptyFolderSnapshot: SelectionSnapshotResponse?
    @State private var reviewingActions = false

    init(scope: ListScope, aroundMessageId: UUID?, environment: AppEnvironment, connection: AppEnvironment.Connection) {
        self.scope = scope
        self.aroundMessageId = aroundMessageId
        self.environment = environment
        self.connection = connection
        _store = State(
            initialValue: MVMailListStore(
                scope: scope, aroundMessageId: aroundMessageId, backend: connection.apiClient,
                ledger: connection.intentLedger, toasts: environment.toasts, referenceCache: connection.referenceCache
            )
        )
    }

    // The screen is built in stages, each its own property, so no single modifier chain grows
    // past what the type checker resolves in reasonable time.
    var body: some View {
        withLifecycle
    }

    private var table: some View {
        MailListTable(store: store, proxy: proxy, actions: tableActions)
            .ignoresSafeArea()
            .overlay { stateOverlay }
            .overlay(alignment: .top) { newMessagesCapsule }
            .overlay(alignment: .bottom) { actionAttentionCapsule }
            .animation(.default, value: store.newMessagesCapsuleCount)
    }

    private var withChrome: some View {
        table
            .navigationTitle(navigationTitle)
            .navigationSubtitle(navigationSubtitle)
            .navigationBarTitleDisplayMode(.inline)
            .navigationBarBackButtonHidden(store.isSelecting)
            .toolbar { toolbarContent }
            .searchable(text: $searchText, prompt: "Search")
            .searchSuggestions { searchSuggestions }
            .onChange(of: searchText) { _, text in store.setFilterText(text) }
    }

    private var withSheets: some View {
        withChrome
            .sheet(item: $optionsRow, onDismiss: runPendingOptionsAction) { row in optionsSheetContent(for: row) }
            .sheet(item: $movePicker, onDismiss: runPendingMove) { request in movePickerContent(for: request) }
    }

    private var withRowConfirmations: some View {
        withSheets
            .alert(
                "Delete this message forever?", isPresented: isPresented($deleteForeverRow),
                presenting: deleteForeverRow
            ) { (row: MessageSummary) in
                Button("Delete Forever", role: .destructive) { store.perform(.deleteForever, on: row.id) }
                Button("Cancel", role: .cancel) {}
            } message: { (_: MessageSummary) in
                Text(Self.deleteForeverMessage)
            }
    }

    private var withBulkConfirmations: some View {
        withRowConfirmations
            .alert(bulkConfirmationTitle, isPresented: isPresented($bulkConfirmation), presenting: bulkConfirmation) {
                (confirmation: BulkConfirmation) in
                Button(confirmation.label, role: .destructive) { confirmBulk(confirmation) }
                Button("Cancel", role: .cancel) {}
            } message: { (_: BulkConfirmation) in
                Text(Self.bulkConfirmationMessage)
            }
    }

    private var withFolderConfirmations: some View {
        withBulkConfirmations
            .alert(emptyFolderTitle, isPresented: isPresented($emptyFolderSnapshot), presenting: emptyFolderSnapshot) {
                (snapshot: SelectionSnapshotResponse) in
                Button("Empty Folder", role: .destructive) { confirmEmptyFolder(snapshot) }
                Button("Cancel", role: .cancel) {}
            } message: { (snapshot: SelectionSnapshotResponse) in
                Text(emptyFolderMessage(snapshot))
            }
    }

    private var withLifecycle: some View {
        withFolderConfirmations
            .task { await start() }
            .task { await tickClock() }
            .onDisappear { stopLiveUpdatesIfPopped() }
            #if DEBUG
                .onChange(of: MailListScreenshotStage.shared.optionsRowId) { _, rowId in
                    if let rowId, let row = store.row(id: rowId) { optionsRow = row }
                }
                .screenshotReady(
                    route: .list(scope, aroundMessageId: aroundMessageId), environment: environment,
                    connection: connection
                )
            #endif
    }

    // MARK: - Stage pieces

    private var navigationTitle: String {
        store.isSelecting ? store.selectionTitle : store.title
    }

    private var navigationSubtitle: String {
        if store.isSelecting { return store.selectionScopeNote ?? "" }
        return store.subtitle(now: now, connection: liveConnectionState)
    }

    private func optionsSheetContent(for row: MessageSummary) -> some View {
        optionsSheet(for: row)
            #if DEBUG
                .onAppear { MailListScreenshotStage.shared.isOptionsSheetVisible = true }
            #endif
    }

    private func movePickerContent(for request: MovePickerRequest) -> some View {
        MovePickerSheet(source: request.source, backend: connection.apiClient) { target in
            pendingMove = PendingMove(request: request, target: target)
        }
    }

    private static let deleteForeverMessage = "This removes it from the mail server. It cannot be undone."
    private static let bulkConfirmationMessage =
        "This acts on the whole selection as it stood when you selected it, resolved again at the moment you "
        + "confirm. It cannot be undone."

    private var bulkConfirmationTitle: String {
        bulkConfirmation?.title ?? ""
    }

    private func confirmBulk(_ confirmation: BulkConfirmation) {
        Task { await store.performBulk(confirmation.action, target: confirmation.target) }
    }

    private var emptyFolderTitle: String {
        "Empty \(folderName)?"
    }

    private func emptyFolderMessage(_ snapshot: SelectionSnapshotResponse) -> String {
        "This permanently deletes \(snapshot.count) messages from the mail server. It cannot be undone."
    }

    private func confirmEmptyFolder(_ snapshot: SelectionSnapshotResponse) {
        Task { await store.emptyFolder(confirmed: snapshot) }
    }

    /// Keeps "Updated … ago" current while the list stays on screen.
    private func tickClock() async {
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(30))
            now = Date()
        }
    }

    // MARK: - Bars

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        if store.isSelecting {
            ToolbarItem(placement: .topBarLeading) {
                Button(store.effectiveSelection.isEmpty ? "Select All" : "Deselect All") {
                    if store.effectiveSelection.isEmpty {
                        Task { await store.selectAll() }
                    } else {
                        store.deselectAll()
                    }
                }
                .accessibilityIdentifier("maillist-select-all")
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("Done") { store.setSelecting(false) }
                    .accessibilityIdentifier("maillist-done")
            }
            // The reader's own bar: Archive and Delete, then everything else under Options.
            ToolbarItem(placement: .bottomBar) {
                Button {
                    bulk(.archive)
                } label: {
                    Label(MVMessageUIAction.archive.title, systemImage: MVSymbols.archive)
                }
                .disabled(store.effectiveSelection.isEmpty)
                .accessibilityIdentifier("maillist-bulk-archive")
            }
            ToolbarItem(placement: .bottomBar) {
                Button {
                    bulk(.trash)
                } label: {
                    Label(MVMessageUIAction.delete.title, systemImage: MVSymbols.delete)
                }
                .disabled(store.effectiveSelection.isEmpty)
                .accessibilityIdentifier("maillist-bulk-trash")
            }
            ToolbarSpacer(.flexible, placement: .bottomBar)
            ToolbarItem(placement: .bottomBar) { selectionOptionsMenu }
        } else {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Select") { store.setSelecting(true) }
                    .accessibilityIdentifier("maillist-select")
            }
            ToolbarItem(placement: .topBarTrailing) { moreMenu }
            ToolbarItem(placement: .bottomBar) { unreadFilterButton }
            ToolbarSpacer(.flexible, placement: .bottomBar)
            DefaultToolbarItem(kind: .search, placement: .bottomBar)
            ToolbarSpacer(.flexible, placement: .bottomBar)
            ToolbarItem(placement: .bottomBar) { composeButton }
        }
    }

    /// Everything the selection can do besides Archive and Delete, the way the reader's Options
    /// menu holds everything besides those two.
    private var selectionOptionsMenu: some View {
        Menu {
            Section {
                bulkButton(.markRead, .markRead)
                bulkButton(.markUnread, .markUnread)
                bulkButton(.star, .flag)
                bulkButton(.unstar, .unflag)
            }
            Section {
                Button {
                    presentBulkMove()
                } label: {
                    Label(MVMessageUIAction.moveTo.title, systemImage: MVMessageUIAction.moveTo.symbol)
                }
                .accessibilityIdentifier("maillist-bulk-move")
                if isJunkFolder {
                    bulkButton(.notJunk, .notSpam)
                } else {
                    bulkButton(.moveToJunk, .spam)
                }
            }
        } label: {
            Label("Options", systemImage: MVSymbols.options)
        }
        .disabled(store.effectiveSelection.isEmpty)
        .accessibilityIdentifier("maillist-bulk-options")
    }

    private func bulkButton(_ action: MVMessageUIAction, _ bulkAction: MVBulkAction) -> some View {
        Button {
            bulk(bulkAction)
        } label: {
            Label(action.title, systemImage: action.symbol)
        }
    }

    private var isJunkFolder: Bool {
        guard case .folder(_, let folderId) = scope else { return false }
        return store.context.folders[folderId]?.specialUse == "junk"
    }

    private var moreMenu: some View {
        Menu {
            Toggle(
                isOn: Binding(get: { store.threaded }, set: { grouped in Task { await store.setThreaded(grouped) } })
            ) {
                Label("Group by Conversation", systemImage: MVSymbols.groupByConversation)
            }
            if isFolderScope {
                Button {
                    Task { await store.markAllAsRead() }
                } label: {
                    Label("Mark All as Read", systemImage: MVSymbols.markRead)
                }
                Button(role: .destructive) {
                    Task { emptyFolderSnapshot = await store.prepareEmptyFolder() }
                } label: {
                    Label("Empty Folder…", systemImage: MVSymbols.delete)
                }
            }
        } label: {
            Image(systemName: MVSymbols.options)
        }
        .accessibilityLabel("More")
        .accessibilityIdentifier("maillist-more")
    }

    private var unreadFilterButton: some View {
        Button {
            Task { await store.setUnreadOnly(!store.unreadOnly) }
        } label: {
            Image(systemName: store.unreadOnly ? MVSymbols.filterUnreadFilled : MVSymbols.filterUnread)
        }
        .accessibilityLabel(store.unreadOnly ? "Show All Messages" : "Show Only Unread")
        .accessibilityIdentifier("maillist-unread-filter")
    }

    private var composeButton: some View {
        Button {
            environment.presentedCompose = ComposeIntent(kind: .new(accountId: folderAccountId))
        } label: {
            Image(systemName: MVSymbols.compose)
        }
        .accessibilityLabel("Compose")
        .accessibilityIdentifier("maillist-compose")
    }

    @ViewBuilder
    private var searchSuggestions: some View {
        let query = MVMailListStore.effectiveFilterQuery(searchText)
        if !query.isEmpty {
            Button {
                environment.navigationPath.append(.search(initialQuery: query))
            } label: {
                Label("Search all mail for “\(query)”", systemImage: "magnifyingglass")
            }
            .accessibilityIdentifier("maillist-search-all-mail")
        }
    }

    // MARK: - States

    @ViewBuilder
    private var stateOverlay: some View {
        if let error = store.context.neverConnectedError {
            ContentUnavailableView {
                Label(error, systemImage: "exclamationmark.triangle")
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(uiColor: .systemBackground))
        } else {
            switch store.phase {
            case .loading:
                if store.rows.isEmpty { skeleton }
            case .failed(let message, let detail):
                errorState(message: message, detail: detail)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color(uiColor: .systemBackground))
            case .loaded:
                if store.isFilterLoading {
                    ProgressView()
                        .padding(.top, 24)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                } else if store.rows.isEmpty {
                    EmptyStateView(
                        systemImage: "tray", message: store.emptyStateMessage,
                        actionTitle: offersShowAll ? "Show All Messages" : nil,
                        action: offersShowAll ? { Task { await store.setUnreadOnly(false) } } : nil
                    )
                }
            }
        }
    }

    private var offersShowAll: Bool {
        store.unreadOnly && !store.isFilterActive
    }

    private var skeleton: some View {
        VStack(spacing: 0) {
            ForEach(0..<8, id: \.self) { _ in
                MailListRowContent(data: .measurementSample)
                    .redacted(reason: .placeholder)
                Divider().padding(.leading, 68)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(Color(uiColor: .systemBackground))
        .allowsHitTesting(false)
        .accessibilityIdentifier("maillist-loading")
    }

    /// Actions that will not go out on their own — held past their expiry, or failed — with the
    /// choice of sending, retrying or discarding them.
    @ViewBuilder
    private var actionAttentionCapsule: some View {
        if let summary = store.actionAttentionSummary, !store.isSelecting {
            Button {
                reviewingActions = true
            } label: {
                Label(summary, systemImage: MVSymbols.actionFailed)
                    .font(.subheadline.weight(.semibold))
            }
            .buttonStyle(.glass)
            .padding(.bottom, 12)
            .accessibilityIdentifier("maillist-action-attention")
            .confirmationDialog(summary, isPresented: $reviewingActions, titleVisibility: .visible) {
                if store.hasUnsentActions {
                    Button("Send Now") { store.sendUnsentActions() }
                }
                if store.hasFailedActions {
                    Button("Retry") { store.retryFailedActions() }
                }
                Button("Discard", role: .destructive) { store.discardAttentionActions() }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text(
                    "These changes have not reached the server. Discarding one puts the message back where it was."
                )
            }
        }
    }

    @ViewBuilder
    private var newMessagesCapsule: some View {
        let count = store.newMessagesCapsuleCount
        if count > 0 && !store.isSelecting {
            Button {
                if store.hasNewer {
                    Task { await store.jumpToLatest() }
                } else {
                    proxy.scrollToTop()
                }
            } label: {
                Label(count == 1 ? "1 New Message" : "\(count) New Messages", systemImage: "arrow.up")
                    .font(.subheadline.weight(.semibold))
            }
            .buttonStyle(.glass)
            .padding(.top, 8)
            .transition(.move(edge: .top).combined(with: .opacity))
            .accessibilityIdentifier("maillist-new-messages")
        }
    }

    // MARK: - Row actions

    private var tableActions: MailListViewController.Actions {
        MailListViewController.Actions(
            open: { row in open(row) },
            perform: { action, row in route(action, row) },
            showOptions: { row in optionsRow = row },
            openAccounts: { environment.navigationPath.append(.accounts) },
            lastSettledMessageId: { ReaderSourceRegistry.shared.lastSettledMessageId(for: .list(scope)) },
            prefetch: { [threadCache = connection.threadCache] rowIds, urgent in
                if urgent {
                    for rowId in rowIds { threadCache.prefetchUrgently(rowId) }
                } else {
                    threadCache.prefetch(rowIds)
                }
            }
        )
    }

    private func open(_ row: MessageSummary) {
        if store.isDraft(row) {
            environment.presentedCompose = ComposeIntent(kind: .draft(messageId: row.id))
            return
        }
        environment.navigationPath.append(.reader(ReaderContext(source: .list(scope), messageId: row.id)))
    }

    /// Every Options surface — swipe sheet, context menu — routes through here: actions that
    /// need the composer, a picker or a confirmation are presented; everything else goes to the
    /// store.
    private func route(_ action: MVMessageUIAction, _ row: MessageSummary) {
        switch action {
        case .reply: environment.presentedCompose = ComposeIntent(kind: .reply(messageId: row.id))
        case .replyAll: environment.presentedCompose = ComposeIntent(kind: .replyAll(messageId: row.id))
        case .forward: environment.presentedCompose = ComposeIntent(kind: .forward(messageId: row.id))
        case .moveTo:
            movePicker = MovePickerRequest(
                source: .folders(accountId: row.accountId, excludingFolderId: row.folderId), rowId: row.id
            )
        case .deleteForever: deleteForeverRow = row
        default: store.perform(action, on: row.id)
        }
    }

    private func optionsSheet(for row: MessageSummary) -> some View {
        MailOptionsSheet(
            header: store.rowData(for: row),
            groups: MessageActionSet.actions(for: store.actionContext(for: row, surface: .swipeSheet)),
            actsOnLatestInConversation: store.identity.threaded && (row.threadCount ?? 1) > 1,
            verdictIsSpam: row.verdictIsSpam
        ) { action in
            pendingOptionsAction = PendingRowAction(action: action, row: row)
        }
    }

    private func runPendingOptionsAction() {
        guard let pending = pendingOptionsAction else { return }
        pendingOptionsAction = nil
        route(pending.action, pending.row)
    }

    private func runPendingMove() {
        guard let pending = pendingMove else { return }
        pendingMove = nil
        if let rowId = pending.request.rowId {
            store.perform(.moveTo, on: rowId, target: pending.target)
        } else {
            bulk(.move, target: pending.target)
        }
    }

    // MARK: - Bulk actions

    private func bulk(_ action: MVBulkAction, target: MVMoveTarget? = nil) {
        let selection = store.effectiveSelection
        guard !selection.isEmpty else { return }
        if MVBulkRequestBuilder.needsConfirmation(selection, action: action) {
            bulkConfirmation = BulkConfirmation(action: action, target: target, count: selection.count)
        } else {
            Task { await store.performBulk(action, target: target) }
        }
    }

    /// A unified view's selection spans accounts, so its destinations are the unified views;
    /// a folder's are the folders of its own account.
    private func presentBulkMove() {
        switch scope {
        case .folder(let accountId, let folderId):
            movePicker = MovePickerRequest(
                source: .folders(accountId: accountId, excludingFolderId: folderId), rowId: nil)
        case .unified:
            movePicker = MovePickerRequest(source: .unifiedViews, rowId: nil)
        }
    }

    // MARK: - Lifecycle

    private func start() async {
        #if DEBUG
            if MVFixtureLaunch.isEnabled() { MVMailListFixtures.register() }
        #endif
        #if DEBUG
            MailListScreenshotStage.shared.store = store
        #endif
        // Before any row can push the reader, which finds this store here; held weakly, so
        // the screen keeps owning it.
        ReaderSourceRegistry.shared.register(store, for: .list(scope))
        subscribeToLiveUpdates()
        await store.start()
    }

    /// Kept for as long as the list is on the navigation stack — including while the reader
    /// covers it, since the list stays mounted there and must stay current for Back.
    private func subscribeToLiveUpdates() {
        guard liveToken == nil else { return }
        liveToken = connection.liveEventHub.subscribe(store)
    }

    private func stopLiveUpdatesIfPopped() {
        guard !environment.navigationPath.contains(.list(scope, aroundMessageId: aroundMessageId)),
            let liveToken
        else { return }
        connection.liveEventHub.unsubscribe(liveToken)
        self.liveToken = nil
    }

    private var liveConnectionState: MVConnectionState {
        #if DEBUG
            // Fixture mode has no event stream; its failing one would read as "Connecting…".
            if MVFixtureLaunch.isEnabled() { return .connected }
        #endif
        return connection.liveEventHub.visibleConnectionState
    }

    // MARK: - Helpers

    private var isFolderScope: Bool {
        if case .folder = scope { return true }
        return false
    }

    private var folderAccountId: UUID? {
        if case .folder(let accountId, _) = scope { return accountId }
        return nil
    }

    private var folderName: String {
        guard case .folder(_, let folderId) = scope, let folder = store.context.folders[folderId] else {
            return "Folder"
        }
        return folderDisplayName(
            imapName: folder.imapName, displayName: folder.displayName, specialUse: folder.specialUse)
    }

    private func errorState(message: String, detail: String) -> some View {
        var view = ErrorStateView(message: message) { Task { await store.retry() } }
        view.technicalDetail = detail
        return view
    }

    private func isPresented<T>(_ item: Binding<T?>) -> Binding<Bool> {
        Binding(get: { item.wrappedValue != nil }, set: { if !$0 { item.wrappedValue = nil } })
    }
}

private struct PendingRowAction {
    let action: MVMessageUIAction
    let row: MessageSummary
}

/// The Move picker for one row (`rowId`) or for the selection.
private struct MovePickerRequest: Identifiable {
    let id = UUID()
    let source: MovePickerSheet.Source
    let rowId: UUID?
}

private struct PendingMove {
    let request: MovePickerRequest
    let target: MVMoveTarget
}

/// A bulk action over a select-all selection that cannot be undone, waiting on confirmation.
private struct BulkConfirmation: Identifiable {
    let id = UUID()
    let action: MVBulkAction
    let target: MVMoveTarget?
    let count: Int

    var label: String {
        switch action {
        case .move: return "Move to \(target?.name ?? "Folder")"
        case .trash: return "Move to Trash"
        case .spam: return "Move to Junk"
        case .expunge: return "Delete Forever"
        default: return action.phrase.capitalized
        }
    }

    var title: String {
        "\(label) \(count) \(count == 1 ? "message" : "messages")?"
    }
}
