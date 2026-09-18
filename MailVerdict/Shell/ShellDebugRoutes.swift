#if DEBUG

    import Foundation
    import MailVerdictKit

    /// `/shell/state` — how many `AppEnvironment`s this process has built.
    ///
    /// One environment opens the live stream and starts the intent ledger, so the count is the
    /// number of live streams and ledgers the app is running. Nothing on screen reveals a second
    /// one: the extra streams reconnect, the extra ledgers deliver the same stored actions, and
    /// the only visible effect is the server being hammered and the app's own requests timing out
    /// behind them. This is the measurement that tells the two apart.
    enum ShellDebugRoutes {
        static func register(_ router: inout DebugRouter) {
            router.register("GET", "/shell/state") { _ in
                .encoding(["environmentsCreated": ShellDebugState.shared.environmentsCreated])
            }
        }
    }

    /// Bumped on the main thread from `AppEnvironment.init`, read by the debug bridge on its own
    /// queue — a lock rather than an actor hop, so a request never waits on the main thread.
    final class ShellDebugState: @unchecked Sendable {
        static let shared = ShellDebugState()

        private let lock = NSLock()
        private var created = 0

        var environmentsCreated: Int {
            lock.lock()
            defer { lock.unlock() }
            return created
        }

        func noteEnvironmentCreated() {
            lock.lock()
            defer { lock.unlock() }
            created += 1
        }
    }

#endif
