import Foundation

/// Asks the server again, on a bounded schedule, for whatever a screen is showing from the offline
/// cache while the live stream is up. A saved copy drawn on a timeout or a 503 while the stream
/// stayed connected has nothing else to replace it: no reconnect follows, and a live event may
/// never touch it.
@MainActor
public final class MVSavedCopyRetry {
    /// Seconds before each attempt, counted from the previous one.
    public static let defaultDelays: [TimeInterval] = [3, 10, 30, 60]

    private let delays: [TimeInterval]
    private var task: Task<Void, Never>?
    private var run = 0

    public init(delays: [TimeInterval] = defaultDelays) {
        self.delays = delays
    }

    /// Starts the schedule unless it is already running. Before each attempt `isWanted` is asked
    /// again, and the schedule ends as soon as it says no — the copy was replaced, or the stream
    /// went down and its reconnect will ask instead.
    public func start(while isWanted: @escaping @MainActor () -> Bool, attempt: @escaping @MainActor () async -> Void) {
        guard task == nil, isWanted() else { return }
        run &+= 1
        let current = run
        let delays = delays
        task = Task { [weak self] in
            for delay in delays {
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                guard !Task.isCancelled, isWanted() else { break }
                await attempt()
            }
            guard let self, self.run == current else { return }
            self.task = nil
        }
    }

    public func stop() {
        task?.cancel()
        task = nil
    }
}
