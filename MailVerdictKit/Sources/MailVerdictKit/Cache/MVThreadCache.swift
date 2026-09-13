import Foundation

/// Conversations recently read or likely to be read next, keyed by the list row that opens them,
/// so the reader can draw one the moment it is pushed and only revalidate behind it.
///
/// Rows are fetched ahead of a tap in two ways: urgently when a finger lands on a row (a tap
/// takes long enough that the request is usually back by the time the reader asks), and in the
/// background for the rows on screen, a few at a time. A request already in flight is joined,
/// never repeated. A copy is dropped when a live event says one of its messages changed, and not
/// served at all once it is older than `maxAge`.
@MainActor
public final class MVThreadCache: LiveEventSubscriber {
    public typealias Fetch = @Sendable (UUID) async throws -> ThreadResponse

    public static let capacity = 60
    public static let maxAge: TimeInterval = 600
    /// Background fetches in flight at once; urgent ones do not count against it.
    public static let backgroundConcurrency = 2
    /// Background requests waiting beyond this many are dropped, oldest first — they were for
    /// rows the reader has since scrolled past.
    public static let backgroundQueueLimit = 16

    private struct Entry {
        let thread: ThreadResponse
        let messageIds: Set<UUID>
        let storedAt: Date
        var lastUsed: UInt64
    }

    private let fetch: Fetch
    private let now: @Sendable () -> Date
    private var entries: [UUID: Entry] = [:]
    private var inFlight: [UUID: Task<ThreadResponse, Error>] = [:]
    private var queue: [UUID] = []
    private var runningBackground = 0
    private var useCounter: UInt64 = 0
    private var generation = 0
    /// When each message was last reported changed, on `changeCounter`'s clock — a fetch that
    /// started before one of its own messages changed is not kept. Cleared whenever nothing is in
    /// flight, since only an in-flight fetch can be stale this way.
    private var changeCounter: UInt64 = 0
    private var changedAt: [UUID: UInt64] = [:]

    public init(fetch: @escaping Fetch, now: @escaping @Sendable () -> Date = { Date() }) {
        self.fetch = fetch
        self.now = now
    }

    /// A copy young enough to draw without waiting, or `nil`.
    public func cached(_ rowId: UUID) -> ThreadResponse? {
        guard var entry = entries[rowId], now().timeIntervalSince(entry.storedAt) <= Self.maxAge else { return nil }
        useCounter += 1
        entry.lastUsed = useCounter
        entries[rowId] = entry
        return entry.thread
    }

    /// A fresh read, joining the one already in flight for this row if there is one.
    public func thread(for rowId: UUID) async throws -> ThreadResponse {
        if let running = inFlight[rowId] { return try await running.value }
        return try await start(rowId).value
    }

    public func store(_ thread: ThreadResponse, for rowId: UUID) {
        guard !thread.messages.isEmpty else {
            entries[rowId] = nil
            return
        }
        useCounter += 1
        entries[rowId] = Entry(
            thread: thread, messageIds: Set(thread.messages.map(\.id)), storedAt: now(), lastUsed: useCounter)
        evictIfNeeded()
    }

    /// A finger is on this row: fetch it now, ahead of everything queued.
    public func prefetchUrgently(_ rowId: UUID) {
        guard needsFetch(rowId) else { return }
        queue.removeAll { $0 == rowId }
        _ = start(rowId)
    }

    /// Rows on screen: fetched a few at a time, the most recently asked-for first.
    public func prefetch(_ rowIds: [UUID]) {
        for rowId in rowIds.reversed() where needsFetch(rowId) {
            queue.removeAll { $0 == rowId }
            queue.append(rowId)
        }
        if queue.count > Self.backgroundQueueLimit {
            queue.removeFirst(queue.count - Self.backgroundQueueLimit)
        }
        drainQueue()
    }

    // MARK: LiveEventSubscriber

    public func apply(_ invalidations: [MVLiveInvalidation]) {
        for invalidation in invalidations {
            switch invalidation {
            case .resync:
                entries = [:]
                generation += 1
            case .mailUpdated(_, _, let messageId?, _), .mailDeleted(_, _, let messageId?),
                .verdictIssued(_, let messageId?, _):
                drop(containing: messageId)
            default:
                continue
            }
        }
    }

    // MARK: Internals

    private func needsFetch(_ rowId: UUID) -> Bool {
        inFlight[rowId] == nil && cached(rowId) == nil
    }

    @discardableResult
    private func start(_ rowId: UUID) -> Task<ThreadResponse, Error> {
        let started = generation
        let startedAt = changeCounter
        let task = Task { [fetch] in try await fetch(rowId) }
        inFlight[rowId] = task
        Task { [weak self] in
            let result = try? await task.value
            guard let self else { return }
            if self.inFlight[rowId] == task { self.inFlight[rowId] = nil }
            if let result, started == self.generation, !self.changed(result, rowId: rowId, since: startedAt) {
                self.store(result, for: rowId)
            }
            if self.inFlight.isEmpty { self.changedAt = [:] }
        }
        return task
    }

    private func changed(_ thread: ThreadResponse, rowId: UUID, since startedAt: UInt64) -> Bool {
        ([rowId] + thread.messages.map(\.id)).contains { (changedAt[$0] ?? 0) > startedAt }
    }

    private func drainQueue() {
        while runningBackground < Self.backgroundConcurrency, let rowId = queue.popLast() {
            guard needsFetch(rowId) else { continue }
            runningBackground += 1
            let task = start(rowId)
            Task { [weak self] in
                _ = try? await task.value
                guard let self else { return }
                self.runningBackground -= 1
                self.drainQueue()
            }
        }
    }

    private func drop(containing messageId: UUID) {
        let stale = entries.filter { $0.key == messageId || $0.value.messageIds.contains(messageId) }.map(\.key)
        for rowId in stale { entries[rowId] = nil }
        if !inFlight.isEmpty {
            changeCounter += 1
            changedAt[messageId] = changeCounter
        }
    }

    private func evictIfNeeded() {
        guard entries.count > Self.capacity else { return }
        let excess = entries.count - Self.capacity
        for rowId in entries.sorted(by: { $0.value.lastUsed < $1.value.lastUsed }).prefix(excess).map(\.key) {
            entries[rowId] = nil
        }
    }
}
