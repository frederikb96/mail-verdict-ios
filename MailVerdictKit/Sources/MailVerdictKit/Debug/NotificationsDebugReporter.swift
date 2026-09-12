#if DEBUG

    import Foundation

    /// What `/notifications/state` answers.
    public struct MVNotificationsDebugSnapshot: Codable, Sendable {
        public let mailCount: Int
        public let systemAlertCount: Int
        public let notificationCount: Int

        public init(mailCount: Int, systemAlertCount: Int, notificationCount: Int) {
            self.mailCount = mailCount
            self.systemAlertCount = systemAlertCount
            self.notificationCount = notificationCount
        }
    }

    /// Same lock-protected bridge shape as `MailboxesDebugReporter`.
    public final class NotificationsDebugReporter: @unchecked Sendable {
        public static let shared = NotificationsDebugReporter()

        private let lock = NSLock()
        private var current: MVNotificationsDebugSnapshot?

        public init() {}

        public func report(_ snapshot: MVNotificationsDebugSnapshot) {
            lock.lock()
            defer { lock.unlock() }
            current = snapshot
        }

        public func snapshot() -> MVNotificationsDebugSnapshot? {
            lock.lock()
            defer { lock.unlock() }
            return current
        }
    }

#endif
