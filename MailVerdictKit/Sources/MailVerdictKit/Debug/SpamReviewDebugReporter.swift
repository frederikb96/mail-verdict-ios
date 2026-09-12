#if DEBUG

    import Foundation

    /// What `/spam-review/state` answers.
    public struct MVSpamReviewDebugSnapshot: Codable, Sendable {
        public let itemCount: Int
        public let hasMore: Bool

        public init(itemCount: Int, hasMore: Bool) {
            self.itemCount = itemCount
            self.hasMore = hasMore
        }
    }

    /// Same lock-protected bridge shape as `MailboxesDebugReporter`.
    public final class SpamReviewDebugReporter: @unchecked Sendable {
        public static let shared = SpamReviewDebugReporter()

        private let lock = NSLock()
        private var current: MVSpamReviewDebugSnapshot?

        public init() {}

        public func report(_ snapshot: MVSpamReviewDebugSnapshot) {
            lock.lock()
            defer { lock.unlock() }
            current = snapshot
        }

        public func snapshot() -> MVSpamReviewDebugSnapshot? {
            lock.lock()
            defer { lock.unlock() }
            return current
        }
    }

#endif
