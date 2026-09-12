#if DEBUG

    import Foundation

    /// What `/search/state` answers.
    public struct MVSearchDebugSnapshot: Codable, Sendable {
        public let mode: String
        public let query: String
        public let resultCount: Int
        public let total: Int?
        public let hasMore: Bool
        public let resultsState: String

        public init(mode: String, query: String, resultCount: Int, total: Int?, hasMore: Bool, resultsState: String) {
            self.mode = mode
            self.query = query
            self.resultCount = resultCount
            self.total = total
            self.hasMore = hasMore
            self.resultsState = resultsState
        }
    }

    /// Same lock-protected bridge shape as `MailboxesDebugReporter` — `SearchStore` is
    /// `@MainActor`, the debug route's handler is not.
    public final class SearchDebugReporter: @unchecked Sendable {
        public static let shared = SearchDebugReporter()

        private let lock = NSLock()
        private var current: MVSearchDebugSnapshot?

        public init() {}

        public func report(_ snapshot: MVSearchDebugSnapshot) {
            lock.lock()
            defer { lock.unlock() }
            current = snapshot
        }

        public func snapshot() -> MVSearchDebugSnapshot? {
            lock.lock()
            defer { lock.unlock() }
            return current
        }
    }

#endif
