import Foundation

// URLSession and friends live in FoundationNetworking on Linux, where the free CI runner builds
// this package. On Apple platforms the module does not exist and Foundation already has them.
#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif

/// The account-wide live-update stream, `GET /api/events`.
///
/// Deliberately generic: it hands every caller a raw `MVSseRecord` (an event name plus its JSON
/// data) rather than decoding specific event types itself — the backend's event catalogue
/// (`verdict_issued`, `resync`, …) is modelled alongside the rest of `Models/`, not here, so this
/// client does not need to change shape every time that catalogue grows.
///
/// `@MainActor`-isolated rather than protected with locks: every realistic caller is a
/// `@MainActor` store deciding when to (re)connect, and the stream's own event rate is far below
/// anything that would make hopping onto the main actor per line a real cost.
///
/// Every attempt to open the stream goes through `scheduleAttempt(delayNanos:)` and carries a
/// generation number. Together those two make a connection storm structurally impossible: no
/// caller can open attempts closer together than `minAttemptIntervalNanos`, and an attempt whose
/// generation has been superseded cannot schedule a successor, so one dying stream can never
/// produce two live ones however its cancellation and its failure path interleave.
@MainActor
public final class MVSseClient {

    public struct Callbacks: Sendable {
        public var onRecord: @MainActor @Sendable (MVSseRecord) -> Void
        /// Fired for every successfully-parsed record, including a comment-only keepalive that
        /// carries no record at all — a caller's only way to tell "the connection is open and
        /// flowing" apart from "nothing is getting through at all".
        public var onActivity: @MainActor @Sendable () -> Void
        public var onConnected: @MainActor @Sendable () -> Void
        public var onDisconnected: @MainActor @Sendable () -> Void

        public init(
            onRecord: @escaping @MainActor @Sendable (MVSseRecord) -> Void,
            onActivity: @escaping @MainActor @Sendable () -> Void,
            onConnected: @escaping @MainActor @Sendable () -> Void,
            onDisconnected: @escaping @MainActor @Sendable () -> Void
        ) {
            self.onRecord = onRecord
            self.onActivity = onActivity
            self.onConnected = onConnected
            self.onDisconnected = onDisconnected
        }
    }

    nonisolated static let initialBackoffNanos: UInt64 = 2_000_000_000
    nonisolated static let maxBackoffNanos: UInt64 = 30_000_000_000
    /// The floor between two connection attempts, whatever asks for one — a retry, a resume, a
    /// caller's own `connect()`. It bounds the request rate this client can ever put on the
    /// server, independently of whether the backoff is behaving.
    nonisolated static let minAttemptIntervalNanos: UInt64 = 1_000_000_000
    /// How long a stream has to carry traffic before it counts as healthy enough to reset the
    /// backoff. A connection accepted and then dropped immediately is a failure however good its
    /// status line was, so the response headers alone must never reset it: on a link that accepts
    /// and drops, that would hold the retry delay at its minimum forever instead of backing off.
    nonisolated static let healthyStreamInterval: TimeInterval = 10
    /// Fraction of the backoff the jitter can add or subtract, so several clients that lost the
    /// connection at the same moment do not all come back in the same instant.
    nonisolated static let backoffJitterFraction = 0.25
    private static let staleTimeout: TimeInterval = 45
    private static let watchdogIntervalNanos: UInt64 = 10_000_000_000

    private let accountId: String?
    private let requestFactory: MVRequestFactory
    private let urlSessionConfiguration: URLSessionConfiguration
    private let callbacks: Callbacks

    /// The last record id this client has seen, sent back as `Last-Event-ID` on reconnect so the
    /// server can replay anything missed — or answer `resync` when the gap is too large to
    /// replay, which arrives as an ordinary record through `onRecord` like any other.
    private var lastEventId: String?
    private var backoffNanos = MVSseClient.initialBackoffNanos
    private var lastEventTime = Date()
    private var stopped = false
    private var paused = false
    private var streamTask: Task<Void, Never>?
    private var watchdogTask: Task<Void, Never>?
    private var reconnectTask: Task<Void, Never>?
    private var activeByteStream: MVHttpByteStream?
    /// Identifies the one connection attempt entitled to act on this client — to deliver
    /// callbacks, to reset the backoff, or to schedule a successor. Bumped by every scheduling
    /// decision, so anything already in flight is superseded the moment a new attempt is decided.
    private var generation: UInt64 = 0
    private var lastAttemptAt: Date?
    private var connectionOpenedAt: Date?
    /// Whether an attempt is currently running its stream. Read by `connect()` to stay
    /// idempotent; a finished `Task` reports neither cancelled nor running, so the state has to
    /// be tracked rather than inferred from the task.
    private var attemptLive = false
    /// How many connection attempts this client has started. Every attempt is one request at the
    /// server, so this is the number a test asserts on when it is asking whether the client can
    /// be made to open more streams than it should.
    private(set) var attemptsStarted = 0

    public init(
        accountId: String? = nil,
        requestFactory: MVRequestFactory,
        callbacks: Callbacks,
        urlSessionConfiguration: URLSessionConfiguration = .default
    ) {
        self.accountId = accountId
        self.requestFactory = requestFactory
        self.callbacks = callbacks
        self.urlSessionConfiguration = urlSessionConfiguration
    }

    /// Idempotent: asking for a stream that is already open, or already scheduled, leaves it
    /// alone. Superseding it instead would let a caller that asks repeatedly cancel the
    /// connection it is asking for, over and over, and never hold one.
    public func connect() {
        guard !stopped else { return }
        paused = false
        guard !attemptLive, reconnectTask == nil else { return }
        scheduleAttempt(delayNanos: 0)
    }

    public func disconnect() {
        stopped = true
        generation &+= 1
        cancelInFlight()
        callbacks.onDisconnected()
    }

    /// Closes the stream until `resume()` without retrying — for an app going to the background,
    /// where the socket would die unobserved and the retry backoff would keep growing against a
    /// network the app cannot use.
    public func pause() {
        guard !stopped, !paused else { return }
        paused = true
        generation &+= 1
        cancelInFlight()
    }

    /// Reconnects with the backoff reset, sending the last event id so the server replays what
    /// was missed (or answers `resync`). Still subject to the attempt floor, so a scene phase
    /// flapping between background and foreground cannot turn into a burst of connections.
    public func resume() {
        guard !stopped, paused else { return }
        paused = false
        backoffNanos = Self.initialBackoffNanos
        scheduleAttempt(delayNanos: 0)
    }

    /// The single door every connection attempt goes through. It supersedes whatever is in
    /// flight, applies the attempt floor, and starts exactly one successor.
    private func scheduleAttempt(delayNanos: UInt64) {
        guard !stopped, !paused else { return }
        let delay = max(delayNanos, floorDelayNanos())
        generation &+= 1
        let attempt = generation
        cancelInFlight()

        guard delay > 0 else {
            startAttempt(generation: attempt)
            return
        }
        reconnectTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: delay)
            guard let self, !Task.isCancelled else { return }
            self.startAttempt(generation: attempt)
        }
    }

    private func startAttempt(generation attempt: UInt64) {
        guard !stopped, !paused, attempt == generation else { return }
        lastAttemptAt = Date()
        connectionOpenedAt = nil
        attemptLive = true
        attemptsStarted += 1
        streamTask = Task { [weak self] in await self?.runConnection(generation: attempt) }
    }

    private func cancelInFlight() {
        attemptLive = false
        reconnectTask?.cancel()
        reconnectTask = nil
        streamTask?.cancel()
        streamTask = nil
        activeByteStream?.cancel()
        activeByteStream = nil
        watchdogTask?.cancel()
        watchdogTask = nil
    }

    private func floorDelayNanos() -> UInt64 {
        guard let lastAttemptAt else { return 0 }
        return Self.remainingFloorNanos(sinceLastAttempt: Date().timeIntervalSince(lastAttemptAt))
    }

    private func runConnection(generation attempt: UInt64) async {
        var query: [URLQueryItem] = []
        if let accountId { query.append(URLQueryItem(name: "account_id", value: accountId)) }

        guard var request = try? requestFactory.makeRequest(path: "/api/events", query: query)
        else {
            handleDisconnect(generation: attempt)
            return
        }
        if let lastEventId {
            request.setValue(lastEventId, forHTTPHeaderField: "Last-Event-ID")
        }

        // Only the attempt still holding the current generation owns this flag; a superseded one
        // returning later must not clear a live successor's.
        defer { if attempt == generation { attemptLive = false } }

        let byteStream = MVHttpByteStream()
        guard attempt == generation else { return }
        activeByteStream = byteStream

        var splitter = MVLineSplitter()
        var accumulator = MVSseEventAccumulator()

        do {
            for try await event in byteStream.start(request: request, configuration: urlSessionConfiguration) {
                if Task.isCancelled || attempt != generation { break }
                switch event {
                case .connected:
                    connectionOpenedAt = Date()
                    lastEventTime = Date()
                    callbacks.onConnected()
                    startWatchdog(generation: attempt)
                case .chunk(let data):
                    // Any bytes prove the connection alive — the backend's idle `: keepalive`
                    // comment carries no record, and counting only records would have the
                    // watchdog tear down a healthy, quiet connection every minute.
                    lastEventTime = Date()
                    noteTrafficArrived()
                    callbacks.onActivity()
                    for line in splitter.ingest(data) {
                        if let record = accumulator.ingest(line: line) {
                            handleRecord(record)
                        }
                    }
                }
            }

            if Self.shouldReconnectAfterStreamEnded(cancelled: Task.isCancelled, stopped: stopped) {
                handleDisconnect(generation: attempt)
            }
        } catch {
            if Self.shouldReconnectAfterStreamEnded(cancelled: Task.isCancelled, stopped: stopped) {
                handleDisconnect(generation: attempt)
            }
        }
    }

    /// Whether the read loop ending unexpectedly should trigger a reconnect. `cancelled` is the
    /// case that matters: a reconnect cancels `streamTask`, whose own `for try await` then
    /// unwinds into this same exit path — reacting to that unwind as *another* disconnect would
    /// schedule a second reconnect on top of the one already started. `nonisolated static` so the
    /// rule is testable without the streaming machinery.
    nonisolated static func shouldReconnectAfterStreamEnded(cancelled: Bool, stopped: Bool) -> Bool {
        !cancelled && !stopped
    }

    /// How long a caller asking to connect right now must still wait, given when the last attempt
    /// started. `nonisolated static` so the floor is testable without wall-clock scheduling.
    nonisolated static func remainingFloorNanos(sinceLastAttempt elapsed: TimeInterval) -> UInt64 {
        let minimum = Double(minAttemptIntervalNanos) / 1_000_000_000
        guard elapsed.isFinite, elapsed >= 0, elapsed < minimum else { return 0 }
        return UInt64((minimum - elapsed) * 1_000_000_000)
    }

    /// The next delay after a failed attempt: double, capped, with jitter applied to the value
    /// actually waited rather than to the value carried forward, so the doubling stays exact.
    nonisolated static func nextBackoffNanos(after current: UInt64) -> UInt64 {
        min(current * 2, maxBackoffNanos)
    }

    nonisolated static func jittered(_ nanos: UInt64) -> UInt64 {
        let spread = Double(nanos) * backoffJitterFraction
        guard spread > 0 else { return nanos }
        return UInt64(max(0, Double(nanos) + Double.random(in: -spread...spread)))
    }

    /// Whether a stream that has been open this long has earned a backoff reset.
    nonisolated static func streamIsHealthy(openFor duration: TimeInterval) -> Bool {
        duration >= healthyStreamInterval
    }

    private func noteTrafficArrived() {
        guard backoffNanos != Self.initialBackoffNanos, let connectionOpenedAt else { return }
        guard Self.streamIsHealthy(openFor: Date().timeIntervalSince(connectionOpenedAt)) else { return }
        backoffNanos = Self.initialBackoffNanos
    }

    private func handleRecord(_ record: MVSseRecord) {
        lastEventTime = Date()
        callbacks.onActivity()
        if let id = record.id { lastEventId = id }
        callbacks.onRecord(record)
    }

    private func startWatchdog(generation attempt: UInt64) {
        watchdogTask?.cancel()
        watchdogTask = Task { [weak self] in
            while true {
                try? await Task.sleep(nanoseconds: Self.watchdogIntervalNanos)
                guard let self, !Task.isCancelled, attempt == self.generation else { return }
                if Date().timeIntervalSince(self.lastEventTime) > Self.staleTimeout {
                    self.handleDisconnect(generation: attempt)
                    return
                }
            }
        }
    }

    /// A superseded attempt speaks for nobody: its `onDisconnected` would contradict a newer
    /// attempt's state, and its retry would be a second live stream beside the one already
    /// scheduled.
    private func handleDisconnect(generation attempt: UInt64) {
        guard attempt == generation else { return }
        callbacks.onDisconnected()
        let delay = Self.jittered(backoffNanos)
        backoffNanos = Self.nextBackoffNanos(after: backoffNanos)
        scheduleAttempt(delayNanos: delay)
    }
}
