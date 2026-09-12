import Foundation

/// A reading position that survives rebuilding the page: the message block at the top of the
/// view and how far into it the view sits. Positions are the blocks' document offsets in CSS
/// pixels, which scale by the page's zoom into scroll-view points.
public struct ReaderScrollAnchor: Sendable, Equatable {
    public let elementId: String
    /// Points between the block's top and the top of the visible area.
    public let offset: Double

    public init(elementId: String, offset: Double) {
        self.elementId = elementId
        self.offset = offset
    }

    /// `visibleTop` is the scroll position of the first unobscured point (content offset plus the
    /// top inset). The anchor is the last block starting at or above it.
    public static func capture(
        positions: [(id: String, top: Double)], visibleTop: Double, zoomScale: Double
    ) -> ReaderScrollAnchor? {
        guard let block = positions.last(where: { $0.top * zoomScale <= visibleTop + 0.5 }) ?? positions.first
        else { return nil }
        return ReaderScrollAnchor(elementId: block.id, offset: visibleTop - block.top * zoomScale)
    }

    /// The `visibleTop` that puts the same block back at the same distance, or `nil` when the
    /// block no longer exists.
    public func restoredVisibleTop(positions: [(id: String, top: Double)], zoomScale: Double) -> Double? {
        guard let block = positions.first(where: { $0.id == elementId }) else { return nil }
        return block.top * zoomScale + offset
    }
}
