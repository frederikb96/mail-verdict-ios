import Foundation

/// Paging out of a zoomed page. While a page is zoomed its own drags pan the message and the pager
/// stays still — except when the zoomed content was already pinned at a horizontal edge as the
/// drag began and the drag clearly carries on past it. Then the pager follows the finger from
/// that edge, as Photos does, and turns the page if the drag commits.
///
/// A drag that begins away from the edge never pages, however far it goes: it pans to the edge
/// and stops there, and a second, deliberate drag is what moves on.
public enum MVZoomEdgeHandoff {
    public enum Edge: Sendable, Equatable {
        /// The content's left edge — dragging right past it pages to the newer message.
        case leading
        /// The content's right edge — dragging left past it pages to the older message.
        case trailing
    }

    /// Below this the page counts as at rest: the rubber band settles fractionally off 1.
    public static let restScaleTolerance = 1.01
    /// How close to an edge, in points, still counts as pinned to it.
    public static let edgeTolerance = 1.0
    /// Sideways travel past the edge before the pager starts to follow — the margin that keeps a
    /// small sideways movement while zoomed from ever paging.
    public static let slop = 24.0
    /// How strongly horizontal a drag must be before it can hand off at all.
    public static let horizontalDominance = 1.5
    /// Past this fraction of the page width, a release turns the page.
    public static let commitFraction = 0.3
    /// A quick flick turns the page from a shorter distance.
    public static let flickVelocity = 600.0
    public static let flickDistance = 48.0

    public static func isZoomed(_ zoomScale: Double) -> Bool {
        zoomScale > restScaleTolerance
    }

    /// The edges the content sits at as a drag begins — none at rest zoom, where the pager owns
    /// horizontal drags outright.
    public static func pinnedEdges(
        zoomScale: Double, offsetX: Double, minOffsetX: Double, maxOffsetX: Double
    ) -> Set<Edge> {
        guard isZoomed(zoomScale) else { return [] }
        var edges: Set<Edge> = []
        if offsetX <= minOffsetX + edgeTolerance { edges.insert(.leading) }
        if offsetX >= maxOffsetX - edgeTolerance { edges.insert(.trailing) }
        return edges
    }

    /// How far the pager should follow the finger, or `nil` while the drag is still the page's own.
    public static func handoff(
        pinned: Set<Edge>, translationX: Double, translationY: Double
    ) -> (edge: Edge, distance: Double)? {
        guard abs(translationX) > abs(translationY) * horizontalDominance else { return nil }
        let edge: Edge = translationX > 0 ? .leading : .trailing
        guard pinned.contains(edge) else { return nil }
        let distance = abs(translationX) - slop
        return distance > 0 ? (edge, distance) : nil
    }

    public static func shouldCommit(distance: Double, velocityX: Double, edge: Edge, pageWidth: Double) -> Bool {
        let towardsPage = edge == .leading ? velocityX : -velocityX
        return distance >= pageWidth * commitFraction || (towardsPage >= flickVelocity && distance >= flickDistance)
    }

    public static func direction(for edge: Edge) -> MVAutoAdvanceDirection {
        edge == .leading ? .newer : .older
    }
}
