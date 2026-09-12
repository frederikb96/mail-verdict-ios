#if DEBUG

    import Foundation
    import MailVerdictKit

    /// `GET /push/state` — what this install believes about its own push registration, as the
    /// coordinator last recorded it. Never the APNs token, the relay ticket or the content key.
    enum PushDebugRoutes {
        static func register(_ router: inout DebugRouter) {
            router.register("GET", "/push/state") { _ in
                .encoding(PushDebugState.shared.snapshot)
            }
        }
    }

    struct PushDebugSnapshot: Encodable, Sendable {
        var serverOrigin: String?
        var enabled = false
        var registered = false
        var hasAPNsToken = false
        var ticketExpiresAt: String?
        var lastUpsertAt: String?
        var lastError: String?
        var pendingTap: String?
    }

    /// Written on the main actor, read on the bridge's own queue.
    final class PushDebugState: @unchecked Sendable {
        static let shared = PushDebugState()

        private let lock = NSLock()
        private var current = PushDebugSnapshot()

        var snapshot: PushDebugSnapshot {
            lock.lock()
            defer { lock.unlock() }
            return current
        }

        func update(_ snapshot: PushDebugSnapshot) {
            lock.lock()
            defer { lock.unlock() }
            current = snapshot
        }
    }

#endif
