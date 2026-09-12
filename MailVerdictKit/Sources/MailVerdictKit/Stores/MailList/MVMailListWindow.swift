import Foundation

/// Refreshing the rows a list already holds, in one request (port of the web's
/// `lib/mail-list-window.ts`). A list is a window of rows; after any change the whole window is
/// re-read with a single request sized to it and the fresh rows are spliced over the loaded ones,
/// so a list twenty pages deep costs one request per change, never twenty.
public enum MVMailListWindow {
    public static let pageSize = 50

    /// Rows past the loaded window a refresh reads, so mail arriving at the top does not push
    /// the window's own last rows out of the response.
    static let refreshSlack = 50

    /// The list endpoints' own `limit` ceiling. Rows loaded deeper than this are kept as they
    /// are rather than re-read.
    static let refreshMaxRows = 1000

    public static func refreshLimit(loadedRows: Int) -> Int {
        min(max(loadedRows, 0) + refreshSlack, refreshMaxRows)
    }

    /// Whether `a` sits above `b` in a newest-first list — the server's own
    /// `ORDER BY received_at DESC, id DESC`, where PostgreSQL places a NULL `received_at` first.
    /// Uppercase and lowercase hex order identically, so comparing `uuidString`s matches the
    /// database's byte order.
    public static func sitsAbove(_ a: MessageSummary, _ b: MessageSummary) -> Bool {
        if a.receivedAt != b.receivedAt {
            guard let aDate = a.receivedAt else { return true }
            guard let bDate = b.receivedAt else { return false }
            if aDate != bDate { return aDate > bDate }
        }
        return a.id.uuidString > b.id.uuidString
    }

    /// Splices a freshly read head window over the loaded rows of a window that starts at the
    /// newest message.
    ///
    /// The result covers the stretch the reader had loaded and no more — rows the fresh read
    /// found below the old last row are left for ordinary paging, so a refresh never grows the
    /// list underneath the reader. Rows the fresh read did not reach (only possible once the
    /// window is deeper than one refresh reads) are kept as they were.
    ///
    /// `preserveIds` are rows a fresh read legitimately dropped but that must stay visible — an
    /// unread-only window's rows the reader has since read. Ignored for any row `fresh` covers,
    /// which is authoritative.
    public static func mergeRefreshed(
        current: [MessageSummary], fresh: [MessageSummary], freshHasMore: Bool, currentHasMore: Bool,
        preserveIds: Set<UUID> = []
    ) -> (rows: [MessageSummary], hasMore: Bool) {
        guard let oldLast = current.last else { return (fresh, freshHasMore) }
        let effectiveFresh = withPreserved(fresh, from: current, preserveIds: preserveIds)

        let reachedOldLast =
            !freshHasMore || (effectiveFresh.last.map { !sitsAbove($0, oldLast) } ?? false)
        if reachedOldLast {
            let rows = effectiveFresh.filter { $0.id == oldLast.id || sitsAbove($0, oldLast) }
            return (rows, freshHasMore || rows.count < effectiveFresh.count)
        }

        // The fresh read stopped above the old last row: what it covers is authoritative,
        // everything below where it stopped is kept as it was.
        guard let freshLast = effectiveFresh.last else { return (current, currentHasMore) }
        let freshIds = Set(effectiveFresh.map(\.id))
        let kept = current.filter { !freshIds.contains($0.id) && sitsAbove(freshLast, $0) }
        return (effectiveFresh + kept, currentHasMore)
    }

    /// The same splice for a window that does not start at the newest message (opened around a
    /// message, or restored after relaunch). It is re-read upward from its own last row
    /// (`after: last`), and whatever the read finds above the window's first row is dropped
    /// rather than added: arrivals never enter a window with a gap above it, they only keep
    /// `hasNewer` true for paging to close. The last row is the read's own cursor, so it is kept.
    public static func mergeRefreshedFromBelow(
        current: [MessageSummary], freshAboveLast: [MessageSummary], freshHasMoreNewer: Bool,
        preserveIds: Set<UUID> = []
    ) -> (rows: [MessageSummary], hasNewer: Bool) {
        guard let oldFirst = current.first, let oldLast = current.last else {
            return (freshAboveLast, freshHasMoreNewer)
        }
        let body = Array(current.dropLast())
        let effectiveFresh = withPreserved(freshAboveLast, from: body, preserveIds: preserveIds)

        let reachedOldFirst =
            !freshHasMoreNewer || (effectiveFresh.first.map { !sitsAbove(oldFirst, $0) } ?? false)
        if reachedOldFirst {
            let inside = effectiveFresh.filter { $0.id == oldFirst.id || !sitsAbove($0, oldFirst) }
            let droppedAbove = inside.count < effectiveFresh.count
            return (inside.filter { $0.id != oldLast.id } + [oldLast], freshHasMoreNewer || droppedAbove)
        }

        // The read stopped below the old first row: rows above where it stopped are kept as
        // they were.
        guard let freshFirst = effectiveFresh.first else { return (current, true) }
        let freshIds = Set(effectiveFresh.map(\.id))
        let kept = body.filter { !freshIds.contains($0.id) && sitsAbove($0, freshFirst) }
        return (kept + effectiveFresh.filter { $0.id != oldLast.id } + [oldLast], true)
    }

    /// Appends an older page below the loaded rows — only rows that genuinely sit below the
    /// current last row, so a page fetched against a cursor that a refresh has since moved can
    /// never duplicate or reorder anything.
    public static func appendingOlder(_ page: [MessageSummary], to rows: [MessageSummary]) -> [MessageSummary] {
        guard let last = rows.last else { return page }
        let ids = Set(rows.map(\.id))
        return rows + page.filter { !ids.contains($0.id) && sitsAbove(last, $0) }
    }

    /// Prepends a newer page above the loaded rows, with the same guard from the other side.
    public static func prependingNewer(_ page: [MessageSummary], to rows: [MessageSummary]) -> [MessageSummary] {
        guard let first = rows.first else { return page }
        let ids = Set(rows.map(\.id))
        return page.filter { !ids.contains($0.id) && sitsAbove($0, first) } + rows
    }

    /// Rows in `current` named in `preserveIds` and absent from `fresh`, merged back into it in
    /// the server's own order — before any windowing looks at it, or a preserved row sitting
    /// above the fresh read's own edge would be treated as "not reached" and dropped anyway.
    private static func withPreserved(
        _ fresh: [MessageSummary], from current: [MessageSummary], preserveIds: Set<UUID>
    ) -> [MessageSummary] {
        guard !preserveIds.isEmpty else { return fresh }
        let freshIds = Set(fresh.map(\.id))
        let preserved = current.filter { preserveIds.contains($0.id) && !freshIds.contains($0.id) }
        guard !preserved.isEmpty else { return fresh }
        return (fresh + preserved).sorted { sitsAbove($0, $1) }
    }
}
