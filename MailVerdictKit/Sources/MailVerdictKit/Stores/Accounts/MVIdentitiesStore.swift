import Foundation
import Observation

/// One account's sending identities — list, add, delete, and pick a default. Renaming an
/// existing identity is not a screen this app offers (UX design §2.10 names only these four
/// operations).
@Observable
@MainActor
public final class MVIdentitiesStore {
    public enum LoadState: Equatable {
        case loading
        case loaded
        case failed(String)
    }

    public let accountId: UUID
    public private(set) var identities: [IdentityResponse] = []
    public private(set) var state: LoadState = .loading

    private let apiClient: MVApiClient

    public init(accountId: UUID, apiClient: MVApiClient) {
        self.accountId = accountId
        self.apiClient = apiClient
    }

    public func load() async {
        state = .loading
        do {
            identities = try await apiClient.listIdentities(accountId: accountId)
            state = .loaded
        } catch {
            state = .failed((error as? MVError)?.userMessage ?? "\(error)")
        }
    }

    /// The first identity ever added becomes the default — the same rule the web's own add form
    /// applies, since there is otherwise no default at all to show a star on.
    public func createIdentity(address: String, displayName: String?) async throws {
        let request = IdentityCreate(
            accountId: accountId, address: address, displayName: displayName,
            isDefault: identities.isEmpty
        )
        _ = try await apiClient.createIdentity(request)
        await load()
    }

    public func setDefault(id: UUID) async throws {
        _ = try await apiClient.updateIdentity(id: id, IdentityUpdate(isDefault: true))
        await load()
    }

    public func delete(id: UUID) async throws {
        try await apiClient.deleteIdentity(id: id)
        identities.removeAll { $0.id == id }
    }
}
