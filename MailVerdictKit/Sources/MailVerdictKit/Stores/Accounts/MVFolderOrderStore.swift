import Foundation
import Observation

/// One account's folder order and visibility — drag to reorder, an eye toggle to hide/show,
/// each saved immediately.
@Observable
@MainActor
public final class MVFolderOrderStore {
    public enum LoadState: Equatable {
        case loading
        case loaded
        case failed(String)
    }

    public let accountId: UUID
    public private(set) var folders: [FolderOrderItem] = []
    public private(set) var state: LoadState = .loading

    private let apiClient: MVApiClient

    public init(accountId: UUID, apiClient: MVApiClient) {
        self.accountId = accountId
        self.apiClient = apiClient
    }

    public func load() async {
        state = .loading
        do {
            folders = try await apiClient.getFolderOrder(accountId: accountId).folders
            state = .loaded
        } catch {
            state = .failed((error as? MVError)?.userMessage ?? "\(error)")
        }
    }

    public func move(fromOffsets: IndexSet, toOffset: Int) async throws {
        var reordered = folders
        reordered.move(fromOffsets: fromOffsets, toOffset: toOffset)
        folders = reordered
        do {
            _ = try await apiClient.setFolderOrder(accountId: accountId, order: reordered.map(\.folderId))
        } catch {
            await load()
            throw error
        }
    }

    public func setVisible(folderId: UUID, isVisible: Bool) async throws {
        guard let index = folders.firstIndex(where: { $0.folderId == folderId }) else { return }
        let previous = folders[index]
        folders[index] = FolderOrderItem(
            folderId: previous.folderId, imapName: previous.imapName,
            displayName: previous.displayName, specialUse: previous.specialUse,
            isVisible: isVisible, unreadCount: previous.unreadCount, totalCount: previous.totalCount
        )
        do {
            _ = try await apiClient.updateFolderPrefs(
                folderId: folderId, FolderPrefsUpdate(isVisible: isVisible))
        } catch {
            folders[index] = previous
            throw error
        }
    }
}
