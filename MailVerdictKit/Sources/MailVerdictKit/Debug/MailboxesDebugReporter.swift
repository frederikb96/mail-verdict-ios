#if DEBUG

    import Foundation

    /// What `/mailboxes/state` answers — Freddy's own verification ("same scroll position and
    /// collapse state") read back without a screenshot.
    public struct MVMailboxesDebugSnapshot: Codable, Sendable {
        public let unifiedCollapsed: Bool
        public let accountCollapsed: [Bool]
        public let topVisibleRowId: String
        public let unifiedRowCount: Int
        public let accountSectionCount: Int
        public let bellBadgeCount: Int
        public let hasDeadOutboxBanner: Bool

        public init(
            unifiedCollapsed: Bool, accountCollapsed: [Bool], topVisibleRowId: String, unifiedRowCount: Int,
            accountSectionCount: Int, bellBadgeCount: Int, hasDeadOutboxBanner: Bool
        ) {
            self.unifiedCollapsed = unifiedCollapsed
            self.accountCollapsed = accountCollapsed
            self.topVisibleRowId = topVisibleRowId
            self.unifiedRowCount = unifiedRowCount
            self.accountSectionCount = accountSectionCount
            self.bellBadgeCount = bellBadgeCount
            self.hasDeadOutboxBanner = hasDeadOutboxBanner
        }
    }

    /// A lock-protected holder `MailboxesStore` (`@MainActor`) reports into and the app's
    /// `/mailboxes/state` debug route (a synchronous, non-isolated handler) reads from — the same
    /// shape `DebugLogBuffer` already uses to bridge the same kind of gap.
    public final class MailboxesDebugReporter: @unchecked Sendable {
        public static let shared = MailboxesDebugReporter()

        private let lock = NSLock()
        private var current: MVMailboxesDebugSnapshot?

        public init() {}

        public func report(_ snapshot: MVMailboxesDebugSnapshot) {
            lock.lock()
            defer { lock.unlock() }
            current = snapshot
        }

        public func snapshot() -> MVMailboxesDebugSnapshot? {
            lock.lock()
            defer { lock.unlock() }
            return current
        }
    }

#endif
