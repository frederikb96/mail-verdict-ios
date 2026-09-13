import Foundation

/// One value per key, fetched at most once at a time: callers asking while a fetch is in flight
/// share its result. A successful value is kept with the moment it arrived; a failed fetch keeps
/// nothing, so the next caller tries again. `invalidate()` drops every value, and a fetch that was
/// already in flight across it still answers its callers but is not kept — it may predate
/// whatever made the old values stale.
@MainActor
final class MVKeyedLoader<Key: Hashable & Sendable, Value: Sendable> {
    private var values: [Key: (value: Value, storedAt: Date)] = [:]
    private var tasks: [Key: Task<Value?, Never>] = [:]
    private var generation = 0
    private let now: @Sendable () -> Date

    init(now: @escaping @Sendable () -> Date) {
        self.now = now
    }

    /// The kept value, or `nil` when there is none or it is older than `maxAge`.
    func cached(_ key: Key, maxAge: TimeInterval? = nil) -> Value? {
        guard let entry = values[key] else { return nil }
        if let maxAge, now().timeIntervalSince(entry.storedAt) > maxAge { return nil }
        return entry.value
    }

    /// Always asks `load` (or joins the request already asking), keeping what it answers.
    func fetch(_ key: Key, _ load: @escaping @Sendable () async throws -> Value) async -> Value? {
        if let running = tasks[key] { return await running.value }
        let started = generation
        let task = Task { try? await load() }
        tasks[key] = task
        let value = await task.value
        guard started == generation else { return value }
        tasks[key] = nil
        if let value { values[key] = (value, now()) }
        return value
    }

    /// The kept value when it is younger than `maxAge`, otherwise a fetch.
    func value(_ key: Key, maxAge: TimeInterval, _ load: @escaping @Sendable () async throws -> Value) async
        -> Value?
    {
        if let cached = cached(key, maxAge: maxAge) { return cached }
        return await fetch(key, load)
    }

    func invalidate() {
        values = [:]
        tasks = [:]
        generation += 1
    }
}
