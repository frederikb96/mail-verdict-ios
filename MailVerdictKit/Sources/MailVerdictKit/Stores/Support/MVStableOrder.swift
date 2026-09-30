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

    /// What a "New activity" tap, or scrolling back to the very top, resolves to: the current
    /// fresh list wholesale, nothing held -- exactly `apply`'s own `atTop: true` answer.
    ///
    /// Deliberately not `held + previously shown`: an order already visible before the hold, that
    /// also received a new mail during it, has moved in the server's own order too -- its fresh
    /// position is not derivable from which rows are held and which were already shown, only from
    /// the fresh list itself. The caller keeps that list current the same way it keeps `held`
    /// current, so it is always at hand by the time a take-over can happen at all.
    public static func takeOver<T: Identifiable & Sendable>(fresh: [T]) -> Result<T> {
        Result(rows: fresh, held: [])
    }
}
