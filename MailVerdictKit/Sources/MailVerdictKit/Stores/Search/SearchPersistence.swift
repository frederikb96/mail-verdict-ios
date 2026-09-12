import Foundation

/// Search prefs and the scroll anchor — port of `search-prefs.ts`'s atoms, all in one
/// `UserDefaults`-backed type since `SearchContext` (package `Navigation/Route.swift`) already
/// carries every field the web's separate atoms do (mode, query, account, folders, fields,
/// strictness, sort, dates) and is itself `Codable`.
// `@unchecked Sendable`: see `MVRecentViewRecord`'s own note — `UserDefaults` is thread-safe by
// Apple's documentation, swift-corelibs-foundation just does not say so.
public struct SearchPersistence: @unchecked Sendable {
    private static let contextKey = "mv.search.context"
    private static let anchorKey = "mv.search.anchor"

    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public func loadContext() -> SearchContext? {
        guard let data = defaults.data(forKey: Self.contextKey) else { return nil }
        return try? JSONDecoder().decode(SearchContext.self, from: data)
    }

    public func saveContext(_ context: SearchContext) {
        guard let data = try? JSONEncoder().encode(context) else { return }
        defaults.set(data, forKey: Self.contextKey)
    }

    /// The anchor row id, persisted alongside the identity it was captured under — so restoring
    /// it after a context change (a new search) never applies a stale position from a different
    /// one. `nil` means "no anchor for the current context", whether because none was ever saved
    /// or because the saved one belongs to a different search.
    public func loadAnchor(for context: SearchContext) -> String? {
        guard let data = defaults.data(forKey: Self.anchorKey),
            let saved = try? JSONDecoder().decode(SearchAnchor.self, from: data), saved.context == context
        else {
            return nil
        }
        return saved.rowId
    }

    public func saveAnchor(_ rowId: String?, for context: SearchContext) {
        guard let rowId else {
            defaults.removeObject(forKey: Self.anchorKey)
            return
        }
        let anchor = SearchAnchor(context: context, rowId: rowId)
        guard let data = try? JSONEncoder().encode(anchor) else { return }
        defaults.set(data, forKey: Self.anchorKey)
    }

    private struct SearchAnchor: Codable {
        let context: SearchContext
        let rowId: String
    }
}
