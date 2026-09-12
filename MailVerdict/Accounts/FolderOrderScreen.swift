import MailVerdictKit
import SwiftUI

/// Folder order and visibility — drag to reorder, an eye toggle to hide/show, each saved
/// immediately. A direct port of the web's `FolderOrder`.
struct FolderOrderScreen: View {
    let accountId: UUID
    let environment: AppEnvironment
    let connection: AppEnvironment.Connection

    @State private var store: MVFolderOrderStore?

    var body: some View {
        content
            .navigationTitle("Folders")
            .accessibilityIdentifier("folderorder-screen")
            .toolbar { EditButton() }
            .task {
                if store == nil { store = MVFolderOrderStore(accountId: accountId, apiClient: connection.apiClient) }
                await store?.load()
            }
    }

    @ViewBuilder
    private var content: some View {
        if let store {
            switch store.state {
            case .loading:
                ProgressView()
            case .failed(let message):
                ErrorStateView(message: message) { Task { await store.load() } }
            case .loaded:
                if store.folders.isEmpty {
                    EmptyStateView(systemImage: "folder", message: "No folders available")
                } else {
                    List {
                        ForEach(store.folders) { folder in
                            FolderOrderRow(store: store, folder: folder, environment: environment)
                        }
                        .onMove { offsets, destination in
                            Task { try? await store.move(fromOffsets: offsets, toOffset: destination) }
                        }
                    }
                }
            }
        }
    }
}

private struct FolderOrderRow: View {
    let store: MVFolderOrderStore
    let folder: FolderOrderItem
    let environment: AppEnvironment

    var body: some View {
        HStack {
            Image(systemName: MVSymbols.folderIcon(specialUse: folder.specialUse))
                .foregroundStyle(.secondary)
            Text(folder.displayName ?? folder.imapName)
                .foregroundStyle(folder.isVisible ? .primary : .secondary)
                .strikethrough(!folder.isVisible)
            Spacer()
            if folder.unreadCount > 0 {
                Text("\(folder.unreadCount) unread").font(.caption).foregroundStyle(.secondary)
            }
            Button {
                Task {
                    do {
                        try await store.setVisible(folderId: folder.folderId, isVisible: !folder.isVisible)
                    } catch {
                        let message = (error as? MVError)?.userMessage ?? "\(error)"
                        environment.toasts.show(
                            .init(variant: .error, message: "Could not change visibility: \(message)"))
                    }
                }
            } label: {
                Image(systemName: folder.isVisible ? "eye" : "eye.slash")
            }
            .buttonStyle(.plain)
        }
    }
}
