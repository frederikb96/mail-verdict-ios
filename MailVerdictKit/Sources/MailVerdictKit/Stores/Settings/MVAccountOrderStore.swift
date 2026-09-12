import Foundation
import Observation

/// Account display order — a single, instance-wide preference every account list in the app
/// reads through `GET /api/account-order`. This store only needs to save a new order; showing it
/// applied everywhere else is each of those screens' own concern.
@Observable
@MainActor
public final class MVAccountOrderStore {
    public enum LoadState {
        case loading
        case loaded
        case failed(Error)

        public var isLoading: Bool {
            if case .loading = self { return true }
            return false
        }
    }

    public private(set) var accounts: [AccountResponse] = []
    public private(set) var state: LoadState = .loading

    private let apiClient: MVApiClient

    public init(apiClient: MVApiClient) {
        self.apiClient = apiClient
    }

    public func load() async {
        state = .loading
        do {
            let all = try await apiClient.listAccounts()
            let order = try await apiClient.getAccountOrder().order
            accounts = Self.applying(order: order, to: all)
            state = .loaded
        } catch {
            state = .failed(error)
        }
    }

    /// Accounts named in `order` first, in that order; anything `order` doesn't mention (a newly
    /// added account the stored order predates) follows, in whatever order the server listed it.
    nonisolated static func applying(order: [UUID], to accounts: [AccountResponse]) -> [AccountResponse] {
        var byId: [UUID: AccountResponse] = [:]
        for account in accounts { byId[account.id] = account }
        var ordered = order.compactMap { byId[$0] }
        let orderedIds = Set(order)
        ordered.append(contentsOf: accounts.filter { !orderedIds.contains($0.id) })
        return ordered
    }

    /// Moves the account at `from` to `to` (both local `accounts` indices, as `.onMove` hands a
    /// SwiftUI list) and saves immediately — there is no separate Save step.
    public func move(fromOffsets: IndexSet, toOffset: Int) async throws {
        var reordered = accounts
        reordered.move(fromOffsets: fromOffsets, toOffset: toOffset)
        accounts = reordered
        do {
            _ = try await apiClient.setAccountOrder(order: reordered.map(\.id))
        } catch {
            await load()
            throw error
        }
    }
}
