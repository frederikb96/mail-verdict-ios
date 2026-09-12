import MailVerdictKit
import SwiftUI

/// "Move to…" from the reader: the message's own account's visible folders, filtered as you type.
struct ReaderMoveSheet: View {
    let request: ReaderScreenModel.MoveRequest
    let lookups: ReaderLookups
    let onPick: (UUID) -> Void

    @State private var folders: [FolderResponse] = []
    @State private var query = ""
    @Environment(\.dismiss) private var dismiss

    private var shown: [FolderResponse] {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return folders }
        return folders.filter { name($0).localizedCaseInsensitiveContains(trimmed) }
    }

    var body: some View {
        NavigationStack {
            List(shown) { folder in
                Button {
                    onPick(folder.id)
                    dismiss()
                } label: {
                    Label(name(folder), systemImage: MVSymbols.folderIcon(specialUse: folder.specialUse))
                }
            }
            .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always))
            .navigationTitle("Move to…")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
        .task {
            folders = await lookups.folders(accountId: request.accountId)
                .filter { $0.id != request.currentFolderId && $0.isVisible }
        }
    }

    private func name(_ folder: FolderResponse) -> String {
        folder.displayName ?? folder.imapName
    }
}
