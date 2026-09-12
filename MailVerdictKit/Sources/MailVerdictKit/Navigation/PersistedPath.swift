import Foundation

/// Cold launch restores `[Mailboxes, last List]`, never a reader — Apple Mail's own behaviour,
/// and Freddy's screenshot (a Back chevron to Mailboxes from the list, never from deeper). The
/// root (Mailboxes) is never itself a `Route` case, so the persisted array is everything pushed
/// *after* it.
public enum MVPersistedPath {
    private static let key = "navigationPath"

    /// Already sanitized for cold launch — a caller never needs to repeat the reader-stripping
    /// rule itself.
    public static func load(from defaults: UserDefaults) -> [Route] {
        guard let data = defaults.data(forKey: key),
            let routes = try? JSONDecoder().decode([Route].self, from: data)
        else {
            return []
        }
        return sanitizedForColdLaunch(routes)
    }

    /// Saves the sanitized form, so a relaunch mid-session (a crash, a background eviction) finds
    /// exactly what a deliberate quit-and-relaunch would have.
    public static func save(_ routes: [Route], to defaults: UserDefaults) {
        let sanitized = sanitizedForColdLaunch(routes)
        guard let data = try? JSONEncoder().encode(sanitized) else { return }
        defaults.set(data, forKey: key)
    }

    /// Internal, not private, so the "never a reader" rule itself has its own direct test rather
    /// than only being exercised through `UserDefaults` round-tripping.
    static func sanitizedForColdLaunch(_ routes: [Route]) -> [Route] {
        guard
            let readerIndex = routes.firstIndex(where: {
                if case .reader = $0 { return true }; return false
            })
        else {
            return routes
        }
        return Array(routes[..<readerIndex])
    }
}
