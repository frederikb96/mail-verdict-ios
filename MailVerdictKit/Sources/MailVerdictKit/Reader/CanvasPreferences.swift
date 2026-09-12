import Foundation

/// Per-message canvas choices, most recently set last. Keyed by message rather than sender or
/// globally, as on the web: whether dark rendering looks right is a property of one message's own
/// markup. Capped so the record cannot grow with the mailbox.
public struct MVCanvasChoices: Sendable, Equatable, Codable {
    public struct Entry: Sendable, Equatable, Codable {
        public let messageId: UUID
        public let canvas: MVCanvas
    }

    public static let capacity = 2000

    public private(set) var entries: [Entry] = []

    public init(entries: [Entry] = []) {
        self.entries = entries
    }

    public func choice(for messageId: UUID) -> MVCanvas? {
        entries.last { $0.messageId == messageId }?.canvas
    }

    public mutating func set(_ canvas: MVCanvas, for messageId: UUID) {
        entries.removeAll { $0.messageId == messageId }
        entries.append(Entry(messageId: messageId, canvas: canvas))
        if entries.count > Self.capacity {
            entries.removeFirst(entries.count - Self.capacity)
        }
    }
}

/// `MVCanvasChoices`, persisted in `UserDefaults`.
// `@unchecked Sendable`: `UserDefaults` is thread-safe, but swift-corelibs-foundation does not
// mark it `Sendable` — the same reasoning as `MVRecentViewRecord`.
public struct MVCanvasPreferenceStore: @unchecked Sendable {
    private static let key = "mv.reader.canvasChoices"
    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public func load() -> MVCanvasChoices {
        guard let data = defaults.data(forKey: Self.key),
            let choices = try? JSONDecoder().decode(MVCanvasChoices.self, from: data)
        else { return MVCanvasChoices() }
        return choices
    }

    public func save(_ choices: MVCanvasChoices) {
        if let data = try? JSONEncoder().encode(choices) {
            defaults.set(data, forKey: Self.key)
        }
    }
}
