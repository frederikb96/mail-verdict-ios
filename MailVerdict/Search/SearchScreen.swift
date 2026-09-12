import MailVerdictKit
import SwiftUI

/// Search — text and semantic modes, a chip bar for every filter, and results rendered with the
/// list's own row shape.
struct SearchScreen: View {
    let initialQuery: String?
    let environment: AppEnvironment
    let connection: AppEnvironment.Connection

    @State private var store: SearchStore
    @State private var queryText: String
    @State private var scrollTarget: String?
    @State private var accounts: [AccountResponse] = []
    @State private var foldersByAccount: [UUID: [FolderResponse]] = [:]
    @State private var dateBounds: SearchDateBoundsResponse?
    @State private var isFoldersSheetPresented = false
    @State private var isDatesSheetPresented = false
    @FocusState private var isSearchFieldFocused: Bool

    init(initialQuery: String?, environment: AppEnvironment, connection: AppEnvironment.Connection) {
        self.initialQuery = initialQuery
        self.environment = environment
        self.connection = connection
        let store = SearchStore(apiClient: connection.apiClient, initialQuery: initialQuery)
        self._store = State(initialValue: store)
        self._queryText = State(initialValue: store.context.query)
    }

    var body: some View {
        VStack(spacing: 0) {
            chipBar
            resultsArea
        }
        .navigationTitle("Search")
        .searchable(text: $queryText, placement: .navigationBarDrawer(displayMode: .always))
        .searchFocused($isSearchFieldFocused)
        .onChange(of: queryText) { _, newValue in store.queryChanged(newValue) }
        .scrollPosition(id: $scrollTarget, anchor: .top)
        .sheet(isPresented: $isFoldersSheetPresented) { foldersSheet }
        .sheet(isPresented: $isDatesSheetPresented) { datesSheet }
        .task {
            #if DEBUG
                SearchFixtures.activeStore = store
            #endif
            store.subscribeToLive(connection.liveEventHub)
            ReaderSourceRegistry.shared.register(store, for: .search(store.context))
            isSearchFieldFocused = true
            scrollTarget = store.topVisibleRowId
            async let accountList = try? connection.apiClient.listAccounts()
            async let bounds = try? connection.apiClient.searchDateBounds(
                accountId: store.context.accountId, folderIds: store.context.folderIds
            )
            accounts = await accountList ?? []
            dateBounds = await bounds
            if store.context.query.count >= 2 { await store.runSearch() }
        }
        .onDisappear { store.unsubscribeFromLive(connection.liveEventHub) }
        .onChange(of: scrollTarget) { _, newValue in store.topVisibleRowId = newValue }
        // The reader is keyed by the exact identity a row was pushed with — re-registering
        // under the new context on every chip change keeps that lookup valid.
        .onChange(of: store.context) { _, newContext in
            ReaderSourceRegistry.shared.register(store, for: .search(newContext))
        }
        #if DEBUG
            .screenshotReady(
                route: .search(initialQuery: initialQuery), environment: environment, connection: connection
            )
        #endif
    }

    // MARK: - Chip bar

    private var chipBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                Picker("Mode", selection: modeBinding) {
                    Text("Text").tag(SearchContext.Mode.text)
                    Text("Semantic").tag(SearchContext.Mode.semantic)
                }
                .pickerStyle(.segmented)
                .fixedSize()

                if store.context.mode == .text {
                    fieldsMenu
                } else {
                    strictnessMenu
                }
                sortMenu
                if accounts.count > 1 {
                    accountMenu
                }
                Button {
                    isFoldersSheetPresented = true
                } label: {
                    Chip(text: foldersChipLabel, tint: .accentColor)
                }
                Button {
                    isDatesSheetPresented = true
                } label: {
                    Chip(text: datesChipLabel, tint: .accentColor)
                }
            }
            .padding(.horizontal)
            .padding(.vertical, 8)
        }
    }

    private var modeBinding: Binding<SearchContext.Mode> {
        Binding(get: { store.context.mode }, set: { newMode in applyContext { $0 = $0.withMode(newMode) } })
    }

    private var fieldsMenu: some View {
        Menu {
            ForEach(MVSearchField.allCases, id: \.rawValue) { field in
                Button {
                    toggleField(field)
                } label: {
                    Label(field.rawValue.capitalized, systemImage: selectedFields.contains(field) ? "checkmark" : "")
                }
            }
        } label: {
            Chip(text: "Fields (\(selectedFields.count))", tint: .accentColor)
        }
    }

    private var selectedFields: [MVSearchField] {
        store.context.fields ?? MVSearchField.allCases
    }

    private func toggleField(_ field: MVSearchField) {
        // `MVSearchField` is `Equatable` but not `Hashable`, so this stays array-based rather
        // than reaching for a `Set`.
        var fields = selectedFields
        if fields.contains(field) {
            // A toggle refuses to clear the last field — at least one must always stay on.
            guard fields.count > 1 else { return }
            fields.removeAll { $0 == field }
        } else {
            fields.append(field)
        }
        let ordered = MVSearchField.allCases.filter { fields.contains($0) }
        applyContext { $0 = $0.withFields(ordered) }
    }

    private var strictnessMenu: some View {
        Menu {
            ForEach([MVSemanticStrictness.loose, .balanced, .strict], id: \.rawValue) { strictness in
                Button(strictness.rawValue.capitalized) { applyContext { $0 = $0.withStrictness(strictness) } }
            }
        } label: {
            Chip(text: (store.context.strictness ?? .balanced).rawValue.capitalized, tint: .accentColor)
        }
    }

    private var sortMenu: some View {
        Menu {
            Button("Best Match") { applyContext { $0 = $0.withSort(.relevance) } }
            Button("Newest First") { applyContext { $0 = $0.withSort(.chronological) } }
        } label: {
            Chip(text: store.context.sort == .relevance ? "Best Match" : "Newest First", tint: .accentColor)
        }
    }

    private var accountMenu: some View {
        Menu {
            Button("All Accounts") { applyContext { $0 = $0.withAccountId(nil) } }
            ForEach(accounts) { account in
                Button(account.name) { applyContext { $0 = $0.withAccountId(account.id) } }
            }
        } label: {
            Chip(
                text: accounts.first { $0.id == store.context.accountId }?.name ?? "All Accounts",
                tint: .accentColor
            )
        }
    }

    private var foldersChipLabel: String {
        guard let folderIds = store.context.folderIds else { return "All Folders" }
        return folderIds.isEmpty ? "No Folders" : "\(folderIds.count) Folders"
    }

    private var datesChipLabel: String {
        if store.context.receivedAfter == nil && store.context.receivedBefore == nil { return "Any Time" }
        return "Dates"
    }

    /// Every chip but the query field funnels through here — one place re-runs the search under
    /// the new context, so no chip can forget to.
    private func applyContext(_ mutate: (inout SearchContext) -> Void) {
        var next = store.context
        mutate(&next)
        Task { await store.updateContext(next) }
    }

    // MARK: - Folders and Dates sheets

    private var foldersSheet: some View {
        NavigationStack {
            List {
                Button("Select All") { applyContext { $0 = $0.withFolderIds(nil) } }
                Button("Deselect All") { applyContext { $0 = $0.withFolderIds([]) } }
                ForEach(accountsForFolderSheet) { account in
                    Section(account.name) {
                        ForEach(foldersByAccount[account.id] ?? []) { folder in
                            Button {
                                toggleFolder(folder.id)
                            } label: {
                                HStack {
                                    Text(
                                        folderDisplayName(
                                            imapName: folder.imapName, displayName: folder.displayName,
                                            specialUse: folder.specialUse
                                        )
                                    )
                                    Spacer()
                                    if isFolderSelected(folder.id) {
                                        Image(systemName: "checkmark")
                                    }
                                }
                            }
                            .foregroundStyle(.primary)
                        }
                    }
                }
            }
            .navigationTitle("Folders")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { isFoldersSheetPresented = false }
                }
            }
            .task { await loadFoldersIfNeeded() }
        }
    }

    private var accountsForFolderSheet: [AccountResponse] {
        store.context.accountId.flatMap { id in accounts.filter { $0.id == id } } ?? accounts
    }

    private func isFolderSelected(_ folderId: UUID) -> Bool {
        store.context.folderIds?.contains(folderId) ?? true
    }

    /// `nil` ("every folder") has no explicit id list to mutate — ticking one folder off an
    /// implicit "everything" selection first has to materialize the full set this account's
    /// sheet shows, the same way the web's Folders sheet does.
    private func toggleFolder(_ folderId: UUID) {
        var current =
            store.context.folderIds
            ?? accountsForFolderSheet.flatMap { foldersByAccount[$0.id] ?? [] }.map(\.id)
        if current.contains(folderId) {
            current.removeAll { $0 == folderId }
        } else {
            current.append(folderId)
        }
        applyContext { $0 = $0.withFolderIds(current) }
    }

    private func loadFoldersIfNeeded() async {
        for account in accounts where foldersByAccount[account.id] == nil {
            if let folders = try? await connection.apiClient.listFolders(accountId: account.id) {
                foldersByAccount[account.id] = folders.filter(\.isVisible)
            }
        }
    }

    private var datesSheet: some View {
        NavigationStack {
            Form {
                DatePicker(
                    "From",
                    selection: Binding(
                        get: { store.context.receivedAfter ?? dateBounds?.oldest ?? Date() },
                        set: { newValue in
                            applyContext { $0 = $0.withDates(after: newValue, before: $0.receivedBefore) }
                        }
                    ),
                    displayedComponents: .date
                )
                DatePicker(
                    "To",
                    selection: Binding(
                        get: { store.context.receivedBefore ?? dateBounds?.newest ?? Date() },
                        set: { newValue in applyContext { $0 = $0.withDates(after: $0.receivedAfter, before: newValue) }
                        }
                    ),
                    displayedComponents: .date
                )
                Button("Any Time") { applyContext { $0 = $0.withDates(after: nil, before: nil) } }
            }
            .navigationTitle("Dates")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { isDatesSheetPresented = false }
                }
            }
        }
    }

    // MARK: - Results

    @ViewBuilder
    private var resultsArea: some View {
        switch store.resultsState {
        case .enterQuery:
            EmptyStateView(systemImage: "magnifyingglass", message: "Enter at least 2 characters to search")
        case .selectAFolder:
            EmptyStateView(systemImage: "folder", message: "Select at least one folder to search")
        case .loading:
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        case .error(let message):
            ErrorStateView(message: message) { Task { await store.runSearch() } }
        case .noResults:
            EmptyStateView(systemImage: "magnifyingglass", message: "No results found")
        case .results:
            resultsList
        }
    }

    private var resultsList: some View {
        List {
            Section {
                ForEach(store.results) { result in
                    Button {
                        let identity = store.context
                        environment.navigationPath.append(
                            .reader(ReaderContext(source: .search(identity), messageId: result.id))
                        )
                    } label: {
                        MailRowView(
                            data: result.toMailRowData(showAccountChip: accounts.count > 1, accounts: accounts))
                    }
                    .id("result:\(result.id)")
                }
                if store.hasOlder {
                    ProgressView()
                        .frame(maxWidth: .infinity)
                        .task { await store.loadMore() }
                }
            } header: {
                if let total = store.total {
                    Text("\(total) results")
                }
            }
        }
    }
}

extension SearchContext {
    func withMode(_ mode: SearchContext.Mode) -> SearchContext {
        SearchContext(
            mode: mode, query: query, accountId: accountId, folderIds: folderIds, fields: fields,
            strictness: strictness, sort: sort, receivedAfter: receivedAfter, receivedBefore: receivedBefore
        )
    }
    func withFields(_ fields: [MVSearchField]?) -> SearchContext {
        SearchContext(
            mode: mode, query: query, accountId: accountId, folderIds: folderIds, fields: fields,
            strictness: strictness, sort: sort, receivedAfter: receivedAfter, receivedBefore: receivedBefore
        )
    }
    func withStrictness(_ strictness: MVSemanticStrictness?) -> SearchContext {
        SearchContext(
            mode: mode, query: query, accountId: accountId, folderIds: folderIds, fields: fields,
            strictness: strictness, sort: sort, receivedAfter: receivedAfter, receivedBefore: receivedBefore
        )
    }
    func withSort(_ sort: SearchContext.Sort) -> SearchContext {
        SearchContext(
            mode: mode, query: query, accountId: accountId, folderIds: folderIds, fields: fields,
            strictness: strictness, sort: sort, receivedAfter: receivedAfter, receivedBefore: receivedBefore
        )
    }
    func withAccountId(_ accountId: UUID?) -> SearchContext {
        SearchContext(
            mode: mode, query: query, accountId: accountId, folderIds: folderIds, fields: fields,
            strictness: strictness, sort: sort, receivedAfter: receivedAfter, receivedBefore: receivedBefore
        )
    }
    func withFolderIds(_ folderIds: [UUID]?) -> SearchContext {
        SearchContext(
            mode: mode, query: query, accountId: accountId, folderIds: folderIds, fields: fields,
            strictness: strictness, sort: sort, receivedAfter: receivedAfter, receivedBefore: receivedBefore
        )
    }
    func withDates(after: Date?, before: Date?) -> SearchContext {
        SearchContext(
            mode: mode, query: query, accountId: accountId, folderIds: folderIds, fields: fields,
            strictness: strictness, sort: sort, receivedAfter: after, receivedBefore: before
        )
    }
}

extension SearchResult {
    /// A search result's own variant of the list row: line3 is the recipient list, line4 is the
    /// bold-parsed snippet.
    func toMailRowData(showAccountChip: Bool, accounts: [AccountResponse]) -> MVMailRowData {
        MVMailRowData(
            id: id, isUnread: !isSeen, senderName: extractSenderName(fromAddr),
            dateText: MVDateFormat.relativeDate(receivedAt), pendingSync: pendingSync, subject: subject,
            threadCount: threadCount, isAnswered: isAnswered, hasAttachments: hasAttachments,
            verdictIsSpam: verdictIsSpam ?? false, isStarred: isFlagged,
            line3: formatRecipientList(toAddrs?.addresses),
            line4: parseBoldMarkers(snippet ?? ""), avatarIdentity: extractEmail(fromAddr),
            accountChip: showAccountChip ? accounts.first { $0.id == accountId }?.name : nil
        )
    }
}
