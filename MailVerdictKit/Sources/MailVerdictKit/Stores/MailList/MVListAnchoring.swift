import Foundation

/// The list's scroll geometry, in the scroll view's own coordinates. Every row has the same
/// height, so a row's position is arithmetic rather than a measurement — which is what makes
/// every correction below exact.
public struct MVListGeometry: Equatable, Sendable {
    public var rowHeight: Double
    /// Content y of row 0 — the height of anything shown above the rows (a banner).
    public var firstRowY: Double
    /// Content height below the last row (a paging spinner).
    public var trailingHeight: Double
    /// `adjustedContentInset.top` / `.bottom`.
    public var topInset: Double
    public var bottomInset: Double
    public var viewportHeight: Double

    public init(
        rowHeight: Double, firstRowY: Double = 0, trailingHeight: Double = 0, topInset: Double = 0,
        bottomInset: Double = 0, viewportHeight: Double
    ) {
        self.rowHeight = rowHeight
        self.firstRowY = firstRowY
        self.trailingHeight = trailingHeight
        self.topInset = topInset
        self.bottomInset = bottomInset
        self.viewportHeight = viewportHeight
    }

    /// The part of the viewport not covered by bars.
    public var visibleHeight: Double { max(viewportHeight - topInset - bottomInset, 0) }

    public var minOffsetY: Double { -topInset }

    public func contentHeight(rowCount: Int) -> Double {
        firstRowY + Double(rowCount) * rowHeight + trailingHeight
    }

    public func maxOffsetY(rowCount: Int) -> Double {
        max(minOffsetY, contentHeight(rowCount: rowCount) - viewportHeight + bottomInset)
    }

    public func clamped(_ offsetY: Double, rowCount: Int) -> Double {
        min(max(offsetY, minOffsetY), maxOffsetY(rowCount: rowCount))
    }

    public func rowTop(_ index: Int) -> Double { firstRowY + Double(index) * rowHeight }
}

/// Where the reader is: the row at the top edge of the visible area, and how far into it.
/// Identity plus an offset, never a pixel offset alone — rows above can change.
public struct MVListAnchor: Equatable, Codable, Sendable {
    public let rowId: UUID
    /// From the row's top edge down to the visible area's top edge. Negative while content
    /// above row 0 (a banner) is in view.
    public let offsetInRow: Double

    public init(rowId: UUID, offsetInRow: Double) {
        self.rowId = rowId
        self.offsetInRow = offsetInRow
    }
}

public enum MVListAnchoring {

    /// Within this of the minimum offset counts as "at the top" — a scroll view settles on
    /// fractional offsets, and a reader who has scrolled even one point away is not at the top.
    static let topTolerance = 0.5

    public static func anchor(offsetY: Double, geometry: MVListGeometry, rowIds: [UUID]) -> MVListAnchor? {
        guard !rowIds.isEmpty, geometry.rowHeight > 0 else { return nil }
        let visibleTop = offsetY + geometry.topInset
        let rawIndex = Int(((visibleTop - geometry.firstRowY) / geometry.rowHeight).rounded(.down))
        let index = min(max(rawIndex, 0), rowIds.count - 1)
        return MVListAnchor(rowId: rowIds[index], offsetInRow: visibleTop - geometry.rowTop(index))
    }

    /// The offset putting `anchor` back exactly where it was, or `nil` once its row is gone.
    public static func offsetY(restoring anchor: MVListAnchor, rowIds: [UUID], geometry: MVListGeometry) -> Double? {
        guard let index = rowIds.firstIndex(of: anchor.rowId) else { return nil }
        let offset = geometry.rowTop(index) + anchor.offsetInRow - geometry.topInset
        return geometry.clamped(offset, rowCount: rowIds.count)
    }

    public static func isAtTop(offsetY: Double, geometry: MVListGeometry) -> Bool {
        offsetY <= geometry.minOffsetY + topTolerance
    }

    /// The offset after the rows changed from `oldIds` to `newIds` under a reader at `offsetY`.
    ///
    /// Nothing above the reader may move a row they are looking at: the offset is corrected by
    /// exactly how far the anchor row moved, whatever happened above it — mail arriving, a row
    /// leaving from the middle, a page prepended. If the anchor row itself left, the nearest
    /// survivor stands in for it (port of the web's `nearestSurvivor`).
    ///
    /// The one exception: a reader resting at the very top of a window that starts at the newest
    /// message is watching for new mail, so new rows are shown there rather than compensated
    /// away — the list stays at the top.
    public static func offsetAfterChange(
        offsetY: Double, oldIds: [UUID], newIds: [UUID], geometry: MVListGeometry, windowAtNewestEdge: Bool
    ) -> Double {
        guard !oldIds.isEmpty else { return geometry.minOffsetY }
        if windowAtNewestEdge && isAtTop(offsetY: offsetY, geometry: geometry) {
            return geometry.minOffsetY
        }
        guard let shift = anchorShift(offsetY: offsetY, oldIds: oldIds, newIds: newIds, geometry: geometry) else {
            return geometry.clamped(offsetY, rowCount: newIds.count)
        }
        return geometry.clamped(offsetY + Double(shift) * geometry.rowHeight, rowCount: newIds.count)
    }

    /// How many rows new to the list landed above the reader's anchor in this change — the
    /// "N New Messages" count once they have been compensated in above the viewport.
    public static func newRowsAbove(offsetY: Double, oldIds: [UUID], newIds: [UUID], geometry: MVListGeometry) -> Int {
        guard let anchor = anchor(offsetY: offsetY, geometry: geometry, rowIds: oldIds),
            let survivor = survivor(of: anchor, oldIds: oldIds, newIds: newIds)
        else { return 0 }
        let old = Set(oldIds)
        return newIds[..<survivor.newIndex].filter { !old.contains($0) }.count
    }

    /// Rows the anchor moved by, via its nearest survivor; `nil` when nothing survived — a
    /// different list entirely, which a restore rather than a correction handles.
    static func anchorShift(offsetY: Double, oldIds: [UUID], newIds: [UUID], geometry: MVListGeometry) -> Int? {
        guard let anchor = anchor(offsetY: offsetY, geometry: geometry, rowIds: oldIds),
            let survivor = survivor(of: anchor, oldIds: oldIds, newIds: newIds)
        else { return nil }
        return survivor.newIndex - survivor.oldIndex
    }

    private static func survivor(
        of anchor: MVListAnchor, oldIds: [UUID], newIds: [UUID]
    ) -> (oldIndex: Int, newIndex: Int)? {
        guard let anchorIndex = oldIds.firstIndex(of: anchor.rowId) else { return nil }
        var newIndexById: [UUID: Int] = [:]
        for (index, id) in newIds.enumerated() where newIndexById[id] == nil { newIndexById[id] = index }
        for distance in 0..<oldIds.count {
            let before = anchorIndex - distance
            if before >= 0, let newIndex = newIndexById[oldIds[before]] { return (before, newIndex) }
            let after = anchorIndex + distance
            if distance > 0, after < oldIds.count, let newIndex = newIndexById[oldIds[after]] {
                return (after, newIndex)
            }
        }
        return nil
    }

    /// The smallest scroll that brings row `index` fully into view, or `nil` when it already is
    /// — Back after paging the reader to a row off-screen here lands on that row with the least
    /// movement, and a row still in view leaves the position exactly as it was.
    public static func offsetRevealing(
        rowIndex index: Int, offsetY: Double, geometry: MVListGeometry, rowCount: Int
    ) -> Double? {
        let top = geometry.rowTop(index)
        let bottom = top + geometry.rowHeight
        let visibleTop = offsetY + geometry.topInset
        let visibleBottom = offsetY + geometry.viewportHeight - geometry.bottomInset
        if top >= visibleTop && bottom <= visibleBottom { return nil }
        let target =
            top < visibleTop
            ? top - geometry.topInset
            : bottom - geometry.viewportHeight + geometry.bottomInset
        return geometry.clamped(target, rowCount: rowCount)
    }

    /// Places row `index` a third of the way down the visible area — landing on a message opened
    /// from outside the list, with room to see what comes before it.
    public static func offsetPlacingInUpperThird(rowIndex index: Int, geometry: MVListGeometry, rowCount: Int) -> Double
    {
        let target = geometry.rowTop(index) - geometry.topInset - geometry.visibleHeight / 3
        return geometry.clamped(target, rowCount: rowCount)
    }

    /// Whether the reader is within two screens of either end of the loaded rows — pages load
    /// well before the edge is reached, never at it.
    public static func pagingNeeds(
        offsetY: Double, geometry: MVListGeometry, rowCount: Int
    ) -> (older: Bool, newer: Bool) {
        let margin = 2 * geometry.visibleHeight
        let visibleTop = offsetY + geometry.topInset
        let visibleBottom = offsetY + geometry.viewportHeight - geometry.bottomInset
        let rowsBottom = geometry.rowTop(rowCount)
        return (rowsBottom - visibleBottom < margin, visibleTop - geometry.firstRowY < margin)
    }
}
