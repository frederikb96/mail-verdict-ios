import MailVerdictKit
import SwiftUI

/// The app's root screen — one tap away from everything (UX design §1's own rule). Unified views
/// plus one collapsible section per account, the dead-outbox banner, and entry rows to Spam
/// Review, Accounts and Settings.
struct MailboxesScreen: View {
    let environment: AppEnvironment
    let connection: AppEnvironment.Connection

    @State private var store: MailboxesStore
    @State private var scrollTarget: String?
    @State private var createFolderContext: FolderCreateContext?
    @State private var pendingEmptyFolder: PendingEmptyFolder?
    @State private var pendingDeleteFolder: PendingDeleteFolder?

    init(environment: AppEnvironment, connection: AppEnvironment.Connection) {
        self.environment = environment
        self.connection = connection
        self._store = State(initialValue: MailboxesStore(apiClient: connection.apiClient))
    }

    var body: some View {
        List {
            if let bannerText = store.deadOutboxBannerText {
                DeadOutboxBannerRow(text: bannerText) { environment.navigationPath.append(.accounts) }
            }

            unifiedSection
            ForEach(store.accountSections) { section in
                accountSection(section)
            }
            mailVerdictSection
        }
        .scrollPosition(id: $scrollTarget, anchor: .top)
        .navigationTitle("Mailboxes")
        .navigationBarTitleDisplayMode(.large)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    environment.navigationPath.append(.notifications)
                } label: {
                    Image(systemName: MVSymbols.bell)
                        .overlay(alignment: .topTrailing) {
                            if store.bellBadgeCount > 0 {
                                Text(store.bellBadgeCount > 99 ? "99+" : "\(store.bellBadgeCount)")
                                    .font(.system(size: 9, weight: .bold))
                                    .padding(3)
                                    .background(Circle().fill(.red))
                                    .foregroundStyle(.white)
                                    .offset(x: 8, y: -6)
                            }
                        }
                }
                .accessibilityIdentifier("mailboxes-bell")
            }
        }
        .safeAreaInset(edge: .bottom) {
            bottomBar
        }
        .refreshable { await store.load() }
        .sheet(item: $createFolderContext) { context in
            FolderCreateSheet(
                accountId: context.accountId, parentId: context.parentId, store: store
            )
        }
        .alert("Empty folder?", isPresented: isEmptyFolderAlertPresented, presenting: pendingEmptyFolder) { pending in
            Button("Empty Folder", role: .destructive) {
                Task {
                    try? await store.emptyFolder(
                        accountId: pending.accountId, folderId: pending.folderId,
                        confirmMessageCount: pending.messageCount, snapshotAt: pending.snapshotAt
                    )
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: { pending in
            Text(
                "Empty \(pending.folderName)? This permanently deletes \(pending.messageCount) messages "
                    + "from the mail server. It cannot be undone."
            )
        }
        .alert(
            "Delete folder?", isPresented: isDeleteFolderAlertPresented, presenting: pendingDeleteFolder
        ) { pending in
            Button("Delete", role: .destructive) {
                Task {
                    try? await store.deleteFolder(
                        accountId: pending.accountId, folderId: pending.folderId,
                        confirmMessageCount: pending.messageCount
                    )
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: { pending in
            Text(
                "Delete \(pending.folderName)? This destroys \(pending.messageCount) messages on the mail "
                    + "server. It cannot be undone."
            )
        }
        .task {
            scrollTarget = store.topVisibleRowId
            await store.load()
            store.startSyncStatusPolling()
        }
        .onDisappear { store.stopSyncStatusPolling() }
        .onChange(of: scrollTarget) { _, newValue in store.topVisibleRowId = newValue }
    }

    // MARK: - Unified section

    @ViewBuilder
    private var unifiedSection: some View {
        Section {
            if isUnifiedCollapsed {
                EmptyView()
            } else if store.unifiedRows.isEmpty {
                NavigationLink(value: Route.unifiedViews) {
                    Text("No unified views yet — create one")
                }
            } else {
                ForEach(store.unifiedRows) { row in
                    Button {
                        store.recordViewed(.unified(viewId: row.id, name: row.name))
                        environment.navigationPath.append(
                            .list(.unified(viewId: row.id, name: row.name), aroundMessageId: nil))
                    } label: {
                        UnifiedRowLabel(row: row)
                    }
                    .id(row.anchorId)
                }
            }
        } header: {
            Button {
                store.toggleCollapsed(MailboxesUIState.unifiedKey())
            } label: {
                HStack {
                    Text("Unified")
                    Spacer()
                    Image(systemName: isUnifiedCollapsed ? "chevron.right" : "chevron.down")
                }
            }
            .buttonStyle(.plain)
        }
    }

    private var isUnifiedCollapsed: Bool { store.isCollapsed(MailboxesUIState.unifiedKey()) }

    // MARK: - Account sections

    @ViewBuilder
    private func accountSection(_ section: MailboxesAccountSection) -> some View {
        let collapsed = store.isCollapsed(section.collapseKey)
        Section {
            if collapsed {
                EmptyView()
            } else if section.connectionState == .neverConnected {
                Button {
                    environment.navigationPath.append(.account(section.id))
                } label: {
                    Text(section.stateError ?? "This account has never connected")
                        .foregroundStyle(.red)
                }
            } else {
                ForEach(section.folders) { folder in
                    Button {
                        store.recordViewed(.folder(accountId: section.id, folderId: folder.id))
                        environment.navigationPath.append(
                            .list(.folder(accountId: section.id, folderId: folder.id), aroundMessageId: nil)
                        )
                    } label: {
                        FolderRowLabel(folder: folder)
                    }
                    .id(folder.anchorId)
                    .contextMenu { folderContextMenu(accountId: section.id, folder: folder) }
                }
            }
        } header: {
            accountSectionHeader(section, collapsed: collapsed)
        }
    }

    private func accountSectionHeader(_ section: MailboxesAccountSection, collapsed: Bool) -> some View {
        Button {
            store.toggleCollapsed(section.collapseKey)
        } label: {
            HStack {
                if let emoji = section.emoji { Text(emoji) }
                Text(section.name)
                stateChip(for: section.connectionState)
                Spacer()
                Image(systemName: collapsed ? "chevron.right" : "chevron.down")
            }
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button("Sync Now") { Task { try? await store.triggerSync(accountId: section.id) } }
            Button("New Folder…") { createFolderContext = FolderCreateContext(accountId: section.id, parentId: nil) }
            Button("Account Settings") { environment.navigationPath.append(.account(section.id)) }
        }
    }

    @ViewBuilder
    private func stateChip(for state: MVAccountConnectionState) -> some View {
        switch state {
        case .ok: EmptyView()
        case .retrying: Chip(text: "Retrying", tint: .secondary)
        case .neverConnected: Chip(text: "Error", tint: .red)
        }
    }

    @ViewBuilder
    private func folderContextMenu(accountId: UUID, folder: MailboxesFolderRow) -> some View {
        Button("Mark All as Read") {
            if folder.badgeCount > 0 {
                environment.toasts.show(
                    MVToast(
                        variant: .info,
                        message: "Marking \(folder.badgeCount) messages — this can take a while"
                    )
                )
            }
            Task { try? await store.markAllAsRead(accountId: accountId, folderId: folder.id) }
        }
        Button("Empty Folder…", role: .destructive) {
            Task {
                guard let snapshot = try? await store.mintEmptySelection(accountId: accountId, folderId: folder.id)
                else { return }
                pendingEmptyFolder = PendingEmptyFolder(
                    accountId: accountId, folderId: folder.id, folderName: folder.displayName,
                    messageCount: snapshot.count, snapshotAt: snapshot.snapshotAt
                )
            }
        }
        Button("New Folder Inside…") {
            createFolderContext = FolderCreateContext(accountId: accountId, parentId: folder.id)
        }
        if folder.specialUse == nil {
            Button("Delete Folder…", role: .destructive) {
                pendingDeleteFolder = PendingDeleteFolder(
                    accountId: accountId, folderId: folder.id, folderName: folder.displayName,
                    messageCount: folder.totalCount
                )
            }
        }
        #if DEBUG
            .screenshotReadyRoot(environment: environment, connection: connection)
        #endif
    }

    // MARK: - MailVerdict section

    private var mailVerdictSection: some View {
        Section("MailVerdict") {
            NavigationLink(value: Route.spamReview) {
                Label("Spam Review", systemImage: MVSymbols.spamReview)
            }
            NavigationLink(value: Route.accounts) {
                Label("Accounts", systemImage: MVSymbols.accounts)
            }
            NavigationLink(value: Route.settings) {
                Label("Settings", systemImage: MVSymbols.settings)
            }
        }
    }

    private var bottomBar: some View {
        HStack {
            Button {
                environment.navigationPath.append(.search(initialQuery: nil))
            } label: {
                Label("Search", systemImage: "magnifyingglass")
            }
            .accessibilityIdentifier("mailboxes-search")
            Spacer()
            Button {
                environment.presentedCompose = ComposeIntent(kind: .new(accountId: nil))
            } label: {
                Image(systemName: MVSymbols.compose)
            }
            .accessibilityIdentifier("mailboxes-compose")
        }
        .padding()
        .background(.bar)
    }

    private var isEmptyFolderAlertPresented: Binding<Bool> {
        Binding(get: { pendingEmptyFolder != nil }, set: { if !$0 { pendingEmptyFolder = nil } })
    }

    private var isDeleteFolderAlertPresented: Binding<Bool> {
        Binding(get: { pendingDeleteFolder != nil }, set: { if !$0 { pendingDeleteFolder = nil } })
    }
}

private struct FolderCreateContext: Identifiable {
    let accountId: UUID
    let parentId: UUID?
    var id: String { "\(accountId)-\(parentId?.uuidString ?? "top")" }
}

private struct PendingEmptyFolder {
    let accountId: UUID
    let folderId: UUID
    let folderName: String
    let messageCount: Int
    let snapshotAt: Date
}

private struct PendingDeleteFolder {
    let accountId: UUID
    let folderId: UUID
    let folderName: String
    let messageCount: Int
}

private struct UnifiedRowLabel: View {
    let row: MailboxesUnifiedRow

    var body: some View {
        HStack {
            Text(row.emoji ?? "")
                .opacity(row.emoji == nil ? 0 : 1)
            if row.emoji == nil { Image(systemName: MVSymbols.unifiedViewDefault) }
            Text(row.name)
            if row.contributingAccountEmojis.count > 1 {
                HStack(spacing: -4) {
                    ForEach(Array(row.contributingAccountEmojis.enumerated()), id: \.offset) { _, emoji in
                        Text(emoji).font(.caption2)
                    }
                }
            }
            Spacer()
            if row.unreadCount > 0 {
                Chip(text: "\(row.unreadCount)", tint: .secondary)
            }
        }
        .foregroundStyle(.primary)
    }
}

private struct FolderRowLabel: View {
    let folder: MailboxesFolderRow

    var body: some View {
        HStack {
            Image(systemName: MVSymbols.folderIcon(specialUse: folder.specialUse))
            Text(folder.displayName)
            Spacer()
            if folder.badgeCount > 0 {
                Chip(text: "\(folder.badgeCount)", tint: .secondary)
            }
        }
        .foregroundStyle(.primary)
    }
}

private struct DeadOutboxBannerRow: View {
    let text: String
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(alignment: .top) {
                Image(systemName: "exclamationmark.triangle.fill")
                Text(text)
                Spacer()
            }
        }
        .listRowBackground(MVPalette.deadBannerBackground)
        .foregroundStyle(MVPalette.deadBannerText)
    }
}

private struct FolderCreateSheet: View {
    let accountId: UUID
    let parentId: UUID?
    let store: MailboxesStore

    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var isCreating = false
    @State private var errorText: String?

    var body: some View {
        NavigationStack {
            Form {
                TextField("Folder name", text: $name)
                if let errorText {
                    Text(errorText).foregroundStyle(.red)
                }
            }
            .navigationTitle("New Folder")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Create") { create() }
                        .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty || isCreating)
                }
            }
        }
    }

    private func create() {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        isCreating = true
        Task {
            do {
                _ = try await store.createFolder(accountId: accountId, name: trimmed, parentId: parentId)
                dismiss()
            } catch {
                errorText = (error as? MVError)?.userMessage ?? "\(error)"
            }
            isCreating = false
        }
    }
}
