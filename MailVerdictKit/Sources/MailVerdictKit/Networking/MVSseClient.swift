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

    private static let initialBackoffNanos: UInt64 = 2_000_000_000
    private static let maxBackoffNanos: UInt64 = 30_000_000_000
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
    private var streamTask: Task<Void, Never>?
    private var watchdogTask: Task<Void, Never>?
    private var reconnectTask: Task<Void, Never>?
    private var activeByteStream: MVHttpByteStream?

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

    public func connect() {
        guard !stopped else { return }
        reconnectTask?.cancel()
        streamTask?.cancel()
        activeByteStream?.cancel()
        streamTask = Task { await self.runConnection() }
    }

    public func disconnect() {
        stopped = true
        reconnectTask?.cancel()
        streamTask?.cancel()
        activeByteStream?.cancel()
        watchdogTask?.cancel()
        callbacks.onDisconnected()
    }

    private func runConnection() async {
        var query: [URLQueryItem] = []
        if let accountId { query.append(URLQueryItem(name: "account_id", value: accountId)) }

        guard var request = try? requestFactory.makeRequest(path: "/api/events", query: query)
        else {
            handleDisconnect()
            return
        }
        if let lastEventId {
            request.setValue(lastEventId, forHTTPHeaderField: "Last-Event-ID")
        }

        let byteStream = MVHttpByteStream()
        activeByteStream = byteStream

        var splitter = MVLineSplitter()
        var accumulator = MVSseEventAccumulator()

        do {
            for try await event in byteStream.start(request: request, configuration: urlSessionConfiguration) {
                if Task.isCancelled { break }
                switch event {
                case .connected:
                    backoffNanos = Self.initialBackoffNanos
                    lastEventTime = Date()
                    callbacks.onConnected()
                    startWatchdog()
                case .chunk(let data):
                    for line in splitter.ingest(data) {
                        if let record = accumulator.ingest(line: line) {
                            handleRecord(record)
                        }
                    }
                }
            }

            if Self.shouldReconnectAfterStreamEnded(cancelled: Task.isCancelled, stopped: stopped) {
                handleDisconnect()
            }
        } catch {
            if Self.shouldReconnectAfterStreamEnded(cancelled: Task.isCancelled, stopped: stopped) {
                handleDisconnect()
            }
        }
    }

    /// Whether the read loop ending unexpectedly should trigger a reconnect. `cancelled` is the
    /// case that matters: the watchdog reconnects by cancelling `streamTask`, whose own `for try
    /// await` then unwinds into this same exit path — reacting to that unwind as *another*
    /// disconnect would schedule a second reconnect on top of the one `scheduleReconnect()`
    /// already started. `nonisolated static` so the rule is testable without the streaming
    /// machinery.
    nonisolated static func shouldReconnectAfterStreamEnded(cancelled: Bool, stopped: Bool) -> Bool {
        !cancelled && !stopped
    }

    private func handleRecord(_ record: MVSseRecord) {
        lastEventTime = Date()
        callbacks.onActivity()
        if let id = record.id { lastEventId = id }
        callbacks.onRecord(record)
    }

    private func startWatchdog() {
        watchdogTask?.cancel()
        watchdogTask = Task { [weak self] in
            while true {
                try? await Task.sleep(nanoseconds: Self.watchdogIntervalNanos)
                guard let self, !Task.isCancelled else { return }
                if Date().timeIntervalSince(self.lastEventTime) > Self.staleTimeout {
                    self.scheduleReconnect()
                }
            }
        }
    }

    private func handleDisconnect() {
        callbacks.onDisconnected()
        scheduleReconnect()
    }

    private func scheduleReconnect() {
        reconnectTask?.cancel()
        streamTask?.cancel()
        activeByteStream?.cancel()
        watchdogTask?.cancel()
        guard !stopped else { return }

        let delay = backoffNanos
        backoffNanos = min(backoffNanos * 2, Self.maxBackoffNanos)

        reconnectTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: delay)
            guard let self, !Task.isCancelled else { return }
            self.connect()
        }
    }
}
