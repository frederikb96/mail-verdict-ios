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
                // `requiresConnection` is an on-demand VPN or cellular link a request brings up.
                let online = path.status != .unsatisfied
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

/// One JSON file per server, so intents never replay against a different backend. Records are
/// read one at a time: a record this build cannot read is skipped rather than taking every other
/// intent with it, and a file it cannot read at all is set aside, never overwritten.
public struct MVFileIntentPersistence: MVIntentPersistence {
    public let url: URL

    static let formatVersion = 1

    public init(url: URL) {
        self.url = url
    }

    /// `directory/intents-<hash>.json`, keyed on the server URL with case and a trailing slash
    /// ignored, so one server always maps to one file and two servers never share one.
    public init(directory: URL, serverURL: String) {
        self.url = directory.appendingPathComponent("intents-\(Self.fileKey(serverURL)).json")
    }

    static func fileKey(_ serverURL: String) -> String {
        var normalized = serverURL.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        while normalized.hasSuffix("/") { normalized.removeLast() }
        // FNV-1a, 64 bit: stable across launches and platforms, unlike `Hasher`.
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in normalized.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01b3
        }
        return String(hash, radix: 16)
    }

    private struct File: Codable {
        let version: Int
        let intents: [Record]
    }

    private struct Record: Codable {
        let intent: MVMailIntent?

        init(_ intent: MVMailIntent) {
            self.intent = intent
        }

        init(from decoder: any Decoder) throws {
            intent = try? MVMailIntent(from: decoder)
        }

        func encode(to encoder: any Encoder) throws {
            try intent?.encode(to: encoder)
        }
    }

    public func load() -> [MVMailIntent] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        guard let file = try? JSONDecoder.mvDefault.decode(File.self, from: data),
            file.version <= Self.formatVersion
        else {
            setAside()
            return []
        }
        return file.intents.compactMap(\.intent)
    }

    public func save(_ intents: [MVMailIntent]) {
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let file = File(version: Self.formatVersion, intents: intents.map(Record.init))
            try JSONEncoder.mvDefault.encode(file).write(to: url, options: .atomic)
        } catch {
            // Kept in memory regardless; only a relaunch before the next successful save loses it.
        }
    }

    private func setAside() {
        let aside = url.appendingPathExtension("unreadable")
        try? FileManager.default.removeItem(at: aside)
        try? FileManager.default.moveItem(at: url, to: aside)
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
