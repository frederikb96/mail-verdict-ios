import Foundation
import Observation

/// The Accounts list: every account, its state chip and "synced N ago" line, and the add/edit/
/// delete operations the list screen itself drives (detail, and the per-account sub-screens, are
/// each their own store).
@Observable
@MainActor
public final class MVAccountsListStore {
    public enum LoadState: Equatable {
        case loading
        case loaded
        case failed(String)
    }

    public private(set) var accounts: [AccountResponse] = []
    public private(set) var syncStatuses: [UUID: SyncStatusResponse] = [:]
    public private(set) var state: LoadState = .loading

    private let apiClient: MVApiClient

    public init(apiClient: MVApiClient) {
        self.apiClient = apiClient
    }

    public func load() async {
        state = .loading
        do {
            let loaded = try await apiClient.listAccounts()
            accounts = loaded
            await refreshSyncStatuses()
            state = .loaded
        } catch {
            state = .failed((error as? MVError)?.userMessage ?? "\(error)")
        }
    }

    /// Called on a 30 s timer while this screen is visible (UX design §2.1's own polling rule,
    /// applied here too) — a failed fetch for one account leaves its last-known status in place
    /// rather than clearing the whole dict.
    public func refreshSyncStatuses() async {
        for account in accounts {
            if let status = try? await apiClient.getSyncStatus(accountId: account.id) {
                syncStatuses[account.id] = status
            }
        }
    }

    public func connectionState(for account: AccountResponse) -> MVAccountConnectionState {
        .classify(state: account.state, lastFullSync: syncStatuses[account.id]?.lastFullSync != nil)
    }

    /// Editing and deleting an account are Account Detail's own actions (UX design §2.10) — this
    /// list screen only ever adds one.
    public func createAccount(_ input: MVAccountFormInput) async throws {
        let request = try MVAccountFormModel.buildCreateRequest(input)
        _ = try await apiClient.createAccount(request)
        await load()
    }
}
