import Foundation

#if canImport(Network)
    import Network
#endif

/// Time as the ledger sees it — injectable, so retries and retirement are driven by a test clock
/// rather than by waiting.
public protocol MVIntentClock: Sendable {
    var now: Date { get }
    /// Throws `CancellationError` when the sleeping task is cancelled.
    func sleep(for seconds: TimeInterval) async throws
}

public struct MVSystemIntentClock: MVIntentClock {
    public init() {}

    public var now: Date { Date() }

    public func sleep(for seconds: TimeInterval) async throws {
        try await Task.sleep(nanoseconds: UInt64(max(seconds, 0) * 1_000_000_000))
    }
}

/// Whether the device has a usable network path — nothing is sent while it does not.
@MainActor
public protocol MVConnectivity: AnyObject {
    var isOnline: Bool { get }
    /// `handler` runs on every change.
    func observe(_ handler: @escaping @MainActor (Bool) -> Void)
}

/// For a context with no path monitor: a request that cannot go out fails and is retried.
@MainActor
public final class MVAlwaysOnlineConnectivity: MVConnectivity {
    public init() {}
    public var isOnline: Bool { true }
    public func observe(_ handler: @escaping @MainActor (Bool) -> Void) {}
}

#if canImport(Network)
    @MainActor
    public final class MVNetworkPathConnectivity: MVConnectivity {
        public private(set) var isOnline = true
        private let monitor = NWPathMonitor()
        private var handlers: [@MainActor (Bool) -> Void] = []

        public init() {
            monitor.pathUpdateHandler = { [weak self] path in
                let online = path.status == .satisfied
                Task { @MainActor [weak self] in self?.update(online) }
            }
            monitor.start(queue: DispatchQueue(label: "MailVerdict.connectivity"))
        }

        deinit {
            monitor.cancel()
        }

        public func observe(_ handler: @escaping @MainActor (Bool) -> Void) {
            handlers.append(handler)
        }

        private func update(_ online: Bool) {
            guard online != isOnline else { return }
            isOnline = online
            for handler in handlers { handler(online) }
        }
    }
#endif

/// Where the ledger keeps its intents between launches.
public protocol MVIntentPersistence: Sendable {
    func load() -> [MVMailIntent]
    func save(_ intents: [MVMailIntent])
}

/// One JSON file per server, so intents never replay against a different backend.
public struct MVFileIntentPersistence: MVIntentPersistence {
    public let url: URL

    public init(url: URL) {
        self.url = url
    }

    /// `directory/intents-<server>.json`, the server reduced to a safe file name.
    public init(directory: URL, serverURL: String) {
        let name = serverURL.lowercased().map { $0.isLetter || $0.isNumber ? $0 : "_" }
        self.url = directory.appendingPathComponent("intents-\(String(name)).json")
    }

    public func load() -> [MVMailIntent] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        return (try? JSONDecoder.mvDefault.decode([MVMailIntent].self, from: data)) ?? []
    }

    public func save(_ intents: [MVMailIntent]) {
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder.mvDefault.encode(intents).write(to: url, options: .atomic)
        } catch {
            // Kept in memory regardless; only a relaunch before the next successful save loses it.
        }
    }
}

public final class MVMemoryIntentPersistence: MVIntentPersistence, @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [MVMailIntent]

    public init(_ intents: [MVMailIntent] = []) {
        stored = intents
    }

    public var intents: [MVMailIntent] {
        lock.lock()
        defer { lock.unlock() }
        return stored
    }

    public func load() -> [MVMailIntent] { intents }

    public func save(_ intents: [MVMailIntent]) {
        lock.lock()
        defer { lock.unlock() }
        stored = intents
    }
}
