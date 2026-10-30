#if DEBUG

    import Foundation
    import MailVerdictKit

    /// `/orders/state` -- what the orders list on screen is: the view chosen, how many rows it
    /// holds, and for the ticket timeline where the "Today" marker sits against the middle of the
    /// viewport, in points. The measurement behind "the timeline opens with today centred".
    enum OrdersDebugRoutes {
        static func register(_ router: inout DebugRouter) {
            router.register("GET", "/orders/state") { _ in
                .encoding(OrdersDebugState.shared.snapshot())
            }
        }
    }

    struct OrdersDebugSnapshot: Encodable, Sendable {
        let kind: String?
        let open: Bool?
        let favorites: Bool?
        let rowCount: Int?
        let todayIndex: Int?
        let rowHeight: Double?
        let viewportMidY: Double?
        let markerMidY: Double?
        /// Marker midpoint minus viewport midpoint; near zero when today is centred.
        let markerOffsetFromCenter: Double?
        /// The marker's row is on screen, so `markerMidY` is current rather than stale.
        let markerVisible: Bool
        /// The fullscreen code has drawn its image.
        let codeShown: Bool
    }

    /// Written by the list on the main thread, read by the debug bridge on its own queue.
    final class OrdersDebugState: @unchecked Sendable {
        static let shared = OrdersDebugState()

        private let lock = NSLock()
        private var _markerFrame: CGRect?
        private var _viewportFrame: CGRect?
        private var _todayIndex: Int?
        private var _rowHeight: Double?
        private var _view: OrderViewState?
        private var _rowCount: Int?
        private var _codeShown = false

        var markerFrame: CGRect? {
            get { locked { _markerFrame } }
            set { locked { _markerFrame = newValue } }
        }
        var viewportFrame: CGRect? {
            get { locked { _viewportFrame } }
            set { locked { _viewportFrame = newValue } }
        }
        var todayIndex: Int? {
            get { locked { _todayIndex } }
            set { locked { _todayIndex = newValue } }
        }
        var rowHeight: Double? {
            get { locked { _rowHeight } }
            set { locked { _rowHeight = newValue } }
        }

        var codeShown: Bool {
            get { locked { _codeShown } }
            set { locked { _codeShown = newValue } }
        }

        func record(view: OrderViewState, rowCount: Int) {
            locked {
                _view = view
                _rowCount = rowCount
            }
        }

        func snapshot() -> OrdersDebugSnapshot {
            locked {
                let marker = _markerFrame
                let viewport = _viewportFrame
                return OrdersDebugSnapshot(
                    kind: _view?.kind.rawValue, open: _view?.open, favorites: _view?.favorites,
                    rowCount: _rowCount, todayIndex: _todayIndex, rowHeight: _rowHeight,
                    viewportMidY: viewport.map { Double($0.midY) }, markerMidY: marker.map { Double($0.midY) },
                    markerOffsetFromCenter: marker.flatMap { m in viewport.map { Double(m.midY - $0.midY) } },
                    markerVisible: marker != nil, codeShown: _codeShown)
            }
        }

        private func locked<T>(_ body: () -> T) -> T {
            lock.lock()
            defer { lock.unlock() }
            return body()
        }
    }

#endif
