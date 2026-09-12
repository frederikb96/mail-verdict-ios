import Foundation
import Observation

/// Recipient autocomplete over the backend's contact search — debounced, and only ever showing
/// the answer to the query currently in the field: a slow response to an earlier query must not
/// replace a newer one's.
@Observable
@MainActor
public final class RecipientSuggestionStore {

    public private(set) var results: [ContactSearchHitOut] = []
    public private(set) var query = ""

    private var task: Task<Void, Never>?
    private let debounce: Duration
    private let search: @Sendable (String) async throws -> [ContactSearchHitOut]

    public init(
        debounce: Duration = .milliseconds(200),
        search: @escaping @Sendable (String) async throws -> [ContactSearchHitOut]
    ) {
        self.debounce = debounce
        self.search = search
    }

    public func update(query newQuery: String) {
        task?.cancel()
        query = newQuery
        let trimmed = newQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            results = []
            return
        }
        let debounce = debounce
        let search = search
        task = Task { [weak self] in
            try? await Task.sleep(for: debounce)
            guard !Task.isCancelled else { return }
            let hits = (try? await search(trimmed)) ?? []
            guard let self, !Task.isCancelled, self.query == newQuery else { return }
            self.results = hits
        }
    }

    public func clear() {
        task?.cancel()
        query = ""
        results = []
    }
}
