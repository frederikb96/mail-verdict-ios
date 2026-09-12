import Foundation
import Observation

/// One account's remote-image allowlist — view and delete only; an exception is added from the
/// reader, never from here.
@Observable
@MainActor
public final class MVImageExceptionsStore {
    public enum LoadState: Equatable {
        case loading
        case loaded
        case failed(String)
    }

    public let accountId: UUID
    public private(set) var exceptions: [ImageExceptionResponse] = []
    public private(set) var state: LoadState = .loading

    private let apiClient: MVApiClient

    public init(accountId: UUID, apiClient: MVApiClient) {
        self.accountId = accountId
        self.apiClient = apiClient
    }

    public func load() async {
        state = .loading
        do {
            exceptions = try await apiClient.listImageExceptions(accountId: accountId)
            state = .loaded
        } catch {
            state = .failed((error as? MVError)?.userMessage ?? "\(error)")
        }
    }

    public func delete(id: UUID) async throws {
        try await apiClient.deleteImageException(accountId: accountId, exceptionId: id)
        exceptions.removeAll { $0.id == id }
    }
}
