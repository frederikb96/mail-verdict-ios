import Foundation
import Observation

/// What sits in the pager's side slot.
public enum ReaderSlot: Sendable, Equatable {
    case message(UUID)
    /// The loaded window ends here but the source has more rows to fetch — a spinner page while
    /// it loads.
    case loadingMore
}

/// Where the reader goes after the current message leaves the list.
public enum ReaderRemoval: Sendable, Equatable {
    case advance(to: UUID, direction: MVAutoAdvanceDirection)
    /// Nothing is left on either side — back to the list.
    case exhausted
}

/// Neighbours in list order (index + 1 is the row below: older).
public enum ReaderNeighbourResolver {

    /// Rows the reader has removed itself (an archive, say) are skipped before the list has
    /// caught up. When `current` has left the list entirely — deleted elsewhere — its place is
    /// found in the rows as they were before, and its nearest surviving rows become the
    /// neighbours.
    public static func neighbours(
        of current: UUID, rows: [UUID], previousRows: [UUID], removed: Set<UUID>
    ) -> (older: UUID?, newer: UUID?) {
        let present = Set(rows)
        let usable = { (id: UUID) in present.contains(id) && !removed.contains(id) && id != current }
        let ordered: [UUID]
        if rows.contains(current) {
            ordered = rows
        } else if previousRows.contains(current) {
            ordered = previousRows
        } else {
            return (nil, nil)
        }
        guard let index = ordered.firstIndex(of: current) else { return (nil, nil) }
        let newer = ordered[..<index].reversed().first(where: usable)
        let older = ordered[(index + 1)...].first(where: usable)
        return (older, newer)
    }
}

/// The pager's position in the list it pages through: the current row, what sits either side of
/// it, the direction last paged in, and the rows the reader has removed itself.
///
/// Only identities, never indices — a row inserted or archived above the current one re-derives
/// the neighbours without ever moving the pager.
@Observable
@MainActor
public final class ReaderPagingStore {
    public private(set) var currentId: UUID
    public private(set) var older: ReaderSlot?
    public private(set) var newer: ReaderSlot?
    public private(set) var lastDirection: MVAutoAdvanceDirection = .older
    public private(set) var removedIds: Set<UUID> = []

    /// Called when the list itself dropped the current row (a live delete, a move from another
    /// client) — the pager then slides on the same way as after its own archive.
    @ObservationIgnored public var onCurrentRemovedExternally: (@MainActor (ReaderRemoval) -> Void)?

    @ObservationIgnored private weak var source: (any ReaderListSource)?
    @ObservationIgnored private var knownRows: [UUID]
    @ObservationIgnored private var loadingOlder = false
    @ObservationIgnored private var loadingNewer = false

    public init(openedId: UUID, source: (any ReaderListSource)?) {
        self.currentId = openedId
        self.source = source
        self.knownRows = source?.rowIds ?? []
        recomputeNeighbours(previousRows: knownRows)
    }

    public var olderId: UUID? {
        if case .message(let id) = older { return id }
        return nil
    }

    public var newerId: UUID? {
        if case .message(let id) = newer { return id }
        return nil
    }

    /// Re-reads the source. Returns where to go when the current row has left it.
    @discardableResult
    public func refresh() -> ReaderRemoval? {
        let previous = knownRows
        knownRows = source?.rowIds ?? []
        // A row the reader removed itself has already been left, or closed on.
        if source != nil, !knownRows.contains(currentId), previous.contains(currentId), !removedIds.contains(currentId)
        {
            recomputeNeighbours(previousRows: previous)
            return advanceAway(from: currentId)
        }
        recomputeNeighbours(previousRows: previous)
        return nil
    }

    /// The pager settled on a side slot. Returns whether the current row changed.
    @discardableResult
    public func move(_ direction: MVAutoAdvanceDirection) -> Bool {
        guard let target = direction == .older ? olderId : newerId else { return false }
        currentId = target
        lastDirection = direction
        recomputeNeighbours(previousRows: knownRows)
        return true
    }

    /// The reader removed `id` itself (archive, delete, junk). Removing the current row advances
    /// in the last direction paged, falling back to the other side — the web's `neighbourInCache`.
    public func remove(_ id: UUID) -> ReaderRemoval? {
        removedIds.insert(id)
        guard id == currentId else {
            recomputeNeighbours(previousRows: knownRows)
            return nil
        }
        return advanceAway(from: id)
    }

    /// Undoes `remove` — an Undo, or a request that failed.
    public func restore(_ id: UUID) {
        removedIds.remove(id)
        recomputeNeighbours(previousRows: knownRows)
    }

    /// Fetches the next page of the source when a side slot is waiting on one.
    public func loadMoreIfNeeded() async {
        guard let source else { return }
        if older == .loadingMore, !loadingOlder {
            loadingOlder = true
            await source.loadOlder()
            loadingOlder = false
            refresh()
        }
        if newer == .loadingMore, !loadingNewer {
            loadingNewer = true
            await source.loadNewer()
            loadingNewer = false
            refresh()
        }
    }

    /// Re-derives the neighbours whenever an observable source's rows change. A source that is
    /// not `@Observable` is simply never re-read on its own; paging still re-reads it on settle.
    public func startObservingSource() {
        guard let source else { return }
        withObservationTracking {
            _ = source.rowIds
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                if let removal = self.refresh() {
                    self.onCurrentRemovedExternally?(removal)
                }
                self.startObservingSource()
            }
        }
    }

    private func advanceAway(from id: UUID) -> ReaderRemoval {
        let target = MailActionService.autoAdvanceTarget(
            neighbours: (olderId, newerId), lastDirection: lastDirection)
        guard let target else { return .exhausted }
        let direction: MVAutoAdvanceDirection = target == olderId ? .older : .newer
        currentId = target
        recomputeNeighbours(previousRows: knownRows)
        return .advance(to: target, direction: direction)
    }

    private func recomputeNeighbours(previousRows: [UUID]) {
        guard source != nil else {
            older = nil
            newer = nil
            return
        }
        let found = ReaderNeighbourResolver.neighbours(
            of: currentId, rows: knownRows, previousRows: previousRows, removed: removedIds)
        older = found.older.map(ReaderSlot.message) ?? (source?.hasOlder == true ? .loadingMore : nil)
        newer = found.newer.map(ReaderSlot.message) ?? (source?.hasNewer == true ? .loadingMore : nil)
    }
}
