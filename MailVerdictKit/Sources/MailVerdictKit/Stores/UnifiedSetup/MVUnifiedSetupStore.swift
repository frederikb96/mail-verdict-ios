import Foundation
import Observation

/// The Unified Views setup screen: the views themselves (name, emoji, sidebar order) and which
/// folders, from any account, each one shows. A folder can belong to several views, chosen per
/// folder with a multi-select — a direct port of the web's `unified-setup.tsx`.
@Observable
@MainActor
public final class MVUnifiedSetupStore {
    public enum LoadState {
        case loading
        case loaded
        case failed(Error)

        public var isLoading: Bool {
            if case .loading = self { return true }
            return false
        }
    }

    public private(set) var views: [UnifiedFolderResponse] = []
    public private(set) var accounts: [AccountResponse] = []
    public private(set) var folders: [UUID: [FolderResponse]] = [:]
    public private(set) var state: LoadState = .loading

    private let apiClient: MVApiClient

    public init(apiClient: MVApiClient) {
        self.apiClient = apiClient
    }

    public func load() async {
        state = .loading
        do {
            let loadedViews = try await apiClient.listUnifiedFolders()
            let loadedAccounts = try await apiClient.listAccounts()
            var byAccount: [UUID: [FolderResponse]] = [:]
            for account in loadedAccounts {
                byAccount[account.id] = try await apiClient.listFolders(accountId: account.id)
            }
            views = loadedViews
            accounts = loadedAccounts
            folders = byAccount
            state = .loaded
        } catch {
            state = .failed(error)
        }
    }

    /// A folder's own visible-in-sidebar order, special-use first then alphabetical — the same
    /// rule the Mailboxes overview falls back to when no saved folder order exists.
    public func orderedFolders(accountId: UUID) -> [FolderResponse] {
        let specialUseOrder = ["inbox", "drafts", "sent", "archive", "junk", "trash"]
        return (folders[accountId] ?? []).sorted { lhs, rhs in
            let lhsRank = lhs.specialUse.flatMap { specialUseOrder.firstIndex(of: $0) } ?? specialUseOrder.count
            let rhsRank = rhs.specialUse.flatMap { specialUseOrder.firstIndex(of: $0) } ?? specialUseOrder.count
            if lhsRank != rhsRank { return lhsRank < rhsRank }
            return lhs.imapName < rhs.imapName
        }
    }

    @discardableResult
    public func createView(name: String) async throws -> UnifiedViewResponse {
        let created = try await apiClient.createUnifiedView(UnifiedViewCreate(name: name))
        await load()
        return created
    }

    public func renameView(id: UUID, name: String) async throws {
        _ = try await apiClient.updateUnifiedView(id: id, UnifiedViewUpdate(name: name))
        await load()
    }

    /// `emoji: .some(emoji)` either way — `UnifiedViewUpdate`'s own `encode(to:)` is what turns
    /// `.some(nil)` into an explicit JSON `null` rather than an omitted key, which is what
    /// actually clears it on a route read with `exclude_unset`.
    public func setViewEmoji(id: UUID, emoji: String?) async throws {
        _ = try await apiClient.updateUnifiedView(id: id, UnifiedViewUpdate(emoji: .some(emoji)))
        await load()
    }

    public func deleteView(id: UUID) async throws {
        try await apiClient.deleteUnifiedView(id: id)
        await load()
    }

    /// Reorders the sidebar — the endpoint addresses views by name, not id, the same way a
    /// unified list route does, so `views` (already in the wanted order) is what gets translated.
    public func reorderViews(_ reordered: [UnifiedFolderResponse]) async throws {
        views = reordered
        do {
            _ = try await apiClient.setUnifiedFolderOrder(order: reordered.map(\.unifiedName))
        } catch {
            await load()
            throw error
        }
    }

    /// Saves one folder's complete membership set — every tick in the multi-select replaces the
    /// whole set, since that is what `PATCH /folders/{id}/prefs` takes.
    public func setFolderViews(folderId: UUID, viewIds: [UUID]) async throws {
        _ = try await apiClient.updateFolderPrefs(
            folderId: folderId, FolderPrefsUpdate(unifiedViewIds: viewIds))
        await load()
    }
}
