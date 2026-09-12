#if DEBUG

    import Foundation
    import MailVerdictKit

    /// `/list/state` — where the list on screen is, as its controller last saw it: which list,
    /// the first visible row and the point within it, what is loaded, and the selection. This is
    /// the measurement behind "open a message, go back, same first visible row".
    enum MailListDebugRoutes {
        static func register(_ router: inout DebugRouter) {
            router.register("GET", "/list/state") { _ in
                guard let snapshot = MailListDebugState.shared.current else {
                    return .message("no message list has been shown", status: 404)
                }
                return .encoding(snapshot)
            }
        }
    }

    struct MailListDebugSnapshot: Encodable, Sendable {
        let listIdentity: String
        let firstVisibleRowId: String?
        let offsetInRow: Double?
        let contentOffsetY: Double
        let rowHeight: Double
        let loadedCount: Int
        let hasOlder: Bool
        let hasNewer: Bool
        let newArrivalCount: Int
        let isOnScreen: Bool
        let isSelecting: Bool
        let selectionCount: Int
        let selectionIsPredicate: Bool
        let openedMessageId: String?
        let phase: String
    }

    /// Written by the list controller on the main thread, read by the debug bridge on its own
    /// queue — a lock rather than an actor hop, so a request never waits on the main thread.
    final class MailListDebugState: @unchecked Sendable {
        static let shared = MailListDebugState()

        private let lock = NSLock()
        private var snapshot: MailListDebugSnapshot?

        var current: MailListDebugSnapshot? {
            lock.lock()
            defer { lock.unlock() }
            return snapshot
        }

        func update(_ snapshot: MailListDebugSnapshot) {
            lock.lock()
            defer { lock.unlock() }
            self.snapshot = snapshot
        }
    }

#endif
