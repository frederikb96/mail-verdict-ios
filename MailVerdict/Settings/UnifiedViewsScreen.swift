import Foundation
import MailVerdictKit
import SwiftUI

/// Unified Views setup — the views themselves (name, emoji, sidebar order) and, below, which
/// folders from any account belong to each one. A direct port of the web's `unified-setup.tsx`.
struct UnifiedViewsScreen: View {
    let environment: AppEnvironment
    let connection: AppEnvironment.Connection

    @State private var store: MVUnifiedSetupStore
    @State private var newViewName = ""
    @State private var createError: String?
    /// Shared across every view's rename field — what `.onDisappear` clears, flushing whichever
    /// row was still focused when the screen is left.
    @FocusState private var focusedViewId: UUID?

    init(environment: AppEnvironment, connection: AppEnvironment.Connection) {
        self.environment = environment
        self.connection = connection
        let freshStore = MVUnifiedSetupStore(apiClient: connection.apiClient)
        _store = State(initialValue: freshStore)
        #if DEBUG
            SettingsDebugServices.shared.activeUnifiedSetupStore = freshStore
        #endif
    }

    var body: some View {
        #if DEBUG
            let _ = DebugLogBuffer.shared.append(.info, "screenshot", "unified-views: body evaluated")
        #endif
        // `content` is never empty — `store` exists from the first render, so there is no nil
        // phase for a lifecycle modifier attached here to silently attach to nothing.
        content
            .navigationTitle("Unified Views")
            .accessibilityIdentifier("unifiedviews-screen")
            #if DEBUG
                .screenshotReady(route: .unifiedViews, environment: environment, connection: connection)
                .onAppear { DebugLogBuffer.shared.append(.info, "screenshot", "unified-views: onAppear") }
            #endif
            .onDisappear { focusedViewId = nil }
            .task {
                #if DEBUG
                    DebugLogBuffer.shared.append(.info, "screenshot", "unified-views: screen task start")
                #endif
                await store.load()
                #if DEBUG
                    DebugLogBuffer.shared.append(
                        .info, "screenshot", "unified-views: load() returned, state=\(store.state)")
                #endif
            }
    }

    @ViewBuilder
    private var content: some View {
        switch store.state {
        case .loading:
            ProgressView()
        case .failed(let error):
            ErrorStateView(error: error) { Task { await store.load() } }
        case .loaded:
            List {
                Section {
                    ForEach(store.views) { view in
                        UnifiedViewRow(
                            store: store, view: view, environment: environment, focusedViewId: $focusedViewId)
                    }
                    .onMove { offsets, destination in
                        var reordered = store.views
                        reordered.move(fromOffsets: offsets, toOffset: destination)
                        Task {
                            try? await store.reorderViews(reordered)
                        }
                    }
                }

                Section {
                    HStack {
                        TextField("New view name", text: $newViewName)
                        Button("Add") { Task { await createView() } }
                            .disabled(newViewName.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                    if let createError {
                        Text(createError).font(.footnote).foregroundStyle(.red)
                    }
                }

                if !store.views.isEmpty {
                    ForEach(store.accounts) { account in
                        AccountFolderViewsSection(store: store, account: account)
                    }
                }
            }
            .toolbar { EditButton() }
        }
    }

    private func createView() async {
        let name = newViewName.trimmingCharacters(in: .whitespaces)
        do {
            _ = try await store.createView(name: name)
            newViewName = ""
            createError = nil
        } catch let error as MVError {
            if case .detail(_, 409) = error {
                createError = "A view named \"\(name)\" already exists"
            } else {
                createError = error.mvUserMessage
            }
        } catch {
            createError = error.mvUserMessage
        }
    }
}

private struct UnifiedViewRow: View {
    let store: MVUnifiedSetupStore
    let view: UnifiedFolderResponse
    let environment: AppEnvironment
    var focusedViewId: FocusState<UUID?>.Binding

    @State private var name: String
    @State private var confirmDelete = false

    init(
        store: MVUnifiedSetupStore, view: UnifiedFolderResponse, environment: AppEnvironment,
        focusedViewId: FocusState<UUID?>.Binding
    ) {
        self.store = store
        self.view = view
        self.environment = environment
        self.focusedViewId = focusedViewId
        _name = State(initialValue: view.unifiedName)
    }

    var body: some View {
        HStack {
            EmojiPickerButton(currentEmoji: view.emoji, accessibilityLabel: "Icon for \(view.unifiedName)") {
                emoji in
                Task { try? await store.setViewEmoji(id: view.id, emoji: emoji) }
            }
            TextField("Name", text: $name)
                .focused(focusedViewId, equals: view.id)
                .onSubmit(commitName)
            Text("\(view.folders.count) folder\(view.folders.count == 1 ? "" : "s")")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .swipeActions {
            Button("Delete", role: .destructive) { confirmDelete = true }
        }
        .confirmationDialog(
            "Delete the \"\(view.unifiedName)\" view?",
            isPresented: $confirmDelete, titleVisibility: .visible
        ) {
            Button("Delete view", role: .destructive) {
                Task { try? await store.deleteView(id: view.id) }
            }
        } message: {
            Text("Only the view goes. Its folders and every message in them stay exactly where they are.")
        }
        .onChange(of: view.unifiedName) { _, newValue in name = newValue }
        .onChange(of: focusedViewId.wrappedValue) { old, new in
            if old == view.id, new != view.id { commitName() }
        }
    }

    private func commitName() {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, trimmed != view.unifiedName else {
            name = view.unifiedName
            return
        }
        Task {
            do {
                try await store.renameView(id: view.id, name: trimmed)
            } catch {
                name = view.unifiedName
                environment.toasts.show(
                    .init(variant: .error, message: "Could not rename the view: \(error.mvUserMessage)"))
            }
        }
    }
}

private struct AccountFolderViewsSection: View {
    let store: MVUnifiedSetupStore
    let account: AccountResponse

    var body: some View {
        let folders = store.orderedFolders(accountId: account.id)
        Section(account.name) {
            if folders.isEmpty {
                Text("No folders synced yet").foregroundStyle(.secondary)
            } else {
                ForEach(folders) { folder in
                    FolderViewsMenu(store: store, folder: folder, accountName: account.name)
                }
            }
        }
    }
}

private struct FolderViewsMenu: View {
    let store: MVUnifiedSetupStore
    let folder: FolderResponse
    let accountName: String

    private var folderName: String {
        folderDisplayName(imapName: folder.imapName, displayName: folder.displayName, specialUse: folder.specialUse)
    }

    var body: some View {
        Menu {
            ForEach(store.views) { view in
                Button {
                    toggle(view.id)
                } label: {
                    HStack {
                        Text(view.unifiedName)
                        if folder.unifiedViewIds.contains(view.id) {
                            Image(systemName: "checkmark")
                        }
                    }
                }
            }
        } label: {
            HStack {
                Text(folderName)
                    .foregroundStyle(.primary)
                Spacer()
                Text(chosenSummary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .tint(.primary)
    }

    private var chosenSummary: String {
        let chosen = store.views.filter { folder.unifiedViewIds.contains($0.id) }
        guard !chosen.isEmpty else { return "No view" }
        return chosen.map { $0.unifiedName }.joined(separator: ", ")
    }

    private func toggle(_ viewId: UUID) {
        var ids = folder.unifiedViewIds
        if ids.contains(viewId) {
            ids.removeAll { $0 == viewId }
        } else {
            ids.append(viewId)
        }
        Task { try? await store.setFolderViews(folderId: folder.id, viewIds: ids) }
    }
}
