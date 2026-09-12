import MailVerdictKit
import SwiftUI

/// Move to… — a type-to-filter list of destinations, the account's recent targets first. One
/// message always moves within its own account; a bulk move out of a unified view lists the
/// unified views instead and resolves the folder per account.
struct MovePickerSheet: View {
    enum Source: Equatable {
        /// One account's folders, never offering the folder the messages are already in.
        case folders(accountId: UUID, excludingFolderId: UUID?)
        case unifiedViews
    }

    let source: Source
    let backend: any MVMailListBackend
    let onChoose: (MVMoveTarget) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var targets: [MVMoveTarget] = []
    @State private var query = ""
    @State private var isLoading = true
    @State private var loadError: (any Error)?
    @State private var recentIds: [String] = []

    private let recents = MVRecentMoveTargets()

    var body: some View {
        NavigationStack {
            List(ordered) { target in
                Button {
                    recents.record(targetId: target.id, accountKey: recentKey)
                    onChoose(target)
                    dismiss()
                } label: {
                    Label(target.name, systemImage: target.symbol)
                        .foregroundStyle(.primary)
                }
                .accessibilityIdentifier("move-target-\(target.name)")
            }
            .overlay { overlay }
            .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "Move to…")
            .navigationTitle("Move to…")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
            .task { await load() }
        }
        .accessibilityIdentifier("move-picker")
    }

    @ViewBuilder
    private var overlay: some View {
        if isLoading && targets.isEmpty {
            ProgressView()
        } else if let loadError {
            ErrorStateView(error: loadError) { Task { await load() } }
        } else if ordered.isEmpty {
            ContentUnavailableView.search(text: query)
        }
    }

    private var ordered: [MVMoveTarget] {
        MVMovePicker.ordered(targets, excludingFolderId: excludedFolderId, recentIds: recentIds, query: query)
    }

    private var excludedFolderId: UUID? {
        if case .folders(_, let excluding) = source { return excluding }
        return nil
    }

    private var recentKey: String {
        switch source {
        case .folders(let accountId, _): return accountId.uuidString
        case .unifiedViews: return "unified"
        }
    }

    private func load() async {
        isLoading = true
        loadError = nil
        recentIds = recents.recentIds(accountKey: recentKey)
        do {
            switch source {
            case .folders(let accountId, _):
                let order = try await backend.fetchFolderOrder(accountId: accountId)
                targets = order.folders.map { MVMoveTarget(folder: $0, accountId: accountId) }
            case .unifiedViews:
                targets = try await backend.fetchUnifiedViews().map(MVMoveTarget.init(unifiedView:))
            }
        } catch {
            loadError = error
        }
        isLoading = false
    }
}
