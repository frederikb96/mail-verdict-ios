import Foundation

/// Keeps a live-updating list from moving rows out from under a reader who is scrolled into it --
/// the orders list's own rule (the design's "no jump" requirement), a pure function so both the
/// rule and its tests are independent of any store or network call.
///
/// At the very top, the fresh order is shown at once -- nothing to preserve. Scrolled down, every
/// row already shown keeps its position and gets its content refreshed from `fresh`; a row no
/// longer in `fresh` (deleted, or merged away) drops out; a row new to `fresh` is held back rather
/// than inserted, so nothing shifts under a reader mid-read -- the caller shows it as a "new
/// activity" pill and calls `takeOver(fresh:)` once the reader taps it or scrolls back to the top.
public enum MVStableOrder {

    public struct Result<T: Identifiable>: Sendable where T: Sendable {
        public let rows: [T]
        public let held: [T]

        public init(rows: [T], held: [T]) {
            self.rows = rows
            self.held = held
        }
    }

    public static func apply<T: Identifiable & Sendable>(shown: [T], fresh: [T], atTop: Bool) -> Result<T> {
        if atTop {
            return Result(rows: fresh, held: [])
        }
        let freshById = Dictionary(uniqueKeysWithValues: fresh.map { ($0.id, $0) })
        let rows = shown.compactMap { freshById[$0.id] }
        let shownIds = Set(shown.map(\.id))
        let held = fresh.filter { !shownIds.contains($0.id) }
        return Result(rows: rows, held: held)
    }

    /// What a "New activity" tap, or scrolling back to the very top, resolves to: the full fresh
    /// list, nothing held -- the same result `apply` gives for `atTop: true`, without needing a
    /// second `fresh` array to already be at hand.
    public static func takeOver<T: Identifiable & Sendable>(rows: [T], held: [T]) -> Result<T> {
        guard !held.isEmpty else { return Result(rows: rows, held: []) }
        let heldIds = Set(held.map(\.id))
        return Result(rows: held + rows.filter { !heldIds.contains($0.id) }, held: [])
    }
}
