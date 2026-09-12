#if DEBUG

    import Foundation

    /// An in-memory ring of recent log lines, queryable over the debug bridge.
    ///
    /// `log stream` from the build host is the equivalent of `logcat` and works, but it only
    /// shows what happens *while* it is attached. This keeps the recent past, so an agent — or a
    /// CI step — can act and then ask what happened, which is the order things actually occur in.
    ///
    /// Bounded on purpose: an unbounded buffer in a long-running debug session is a slow leak
    /// that gets blamed on the app.
    public final class DebugLogBuffer: @unchecked Sendable {

        public enum Level: String, Codable, Sendable, Comparable, CaseIterable {
            case debug, info, warning, error

            private var rank: Int {
                switch self {
                case .debug: 0
                case .info: 1
                case .warning: 2
                case .error: 3
                }
            }

            public static func < (lhs: Level, rhs: Level) -> Bool { lhs.rank < rhs.rank }
        }

        public struct Entry: Codable, Sendable {
            public let level: Level
            public let category: String
            public let message: String
            public let at: Date
        }

        public static let shared = DebugLogBuffer()

        private let capacity: Int
        private var entries: [Entry] = []
        private let lock = NSLock()

        public init(capacity: Int = 500) {
            self.capacity = capacity
            entries.reserveCapacity(capacity)
        }

        public func append(_ level: Level, _ category: String, _ message: String) {
            lock.lock()
            defer { lock.unlock() }
            entries.append(Entry(level: level, category: category, message: message, at: Date()))
            if entries.count > capacity {
                entries.removeFirst(entries.count - capacity)
            }
        }

        /// Newest last, so reading it top-to-bottom matches the order things happened. `since`
        /// is for a caller that launches this process repeatedly (a Mac workflow's fixture
        /// sweep, one process per screen) and wants only the current launch's own entries —
        /// there is nothing here to actually separate by launch, since a fresh process starts
        /// this buffer empty anyway, but a caller that cannot be completely sure the previous
        /// launch's process and bridge are gone yet can still ask for "only after I launched
        /// this one" rather than trust that.
        public func snapshot(minimumLevel: Level = .debug, limit: Int = 200, since: Date? = nil) -> [Entry] {
            lock.lock()
            defer { lock.unlock() }
            let filtered = entries.filter { $0.level >= minimumLevel && (since == nil || $0.at > since!) }
            return Array(filtered.suffix(limit))
        }

        public func clear() {
            lock.lock()
            defer { lock.unlock() }
            entries.removeAll(keepingCapacity: true)
        }
    }

#endif
