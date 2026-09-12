import Foundation

/// A folder row cheap enough to paint before the network answers.
public struct MVMailboxesCachedFolder: Codable, Sendable, Equatable, Identifiable {
    public let id: UUID
    public let displayName: String
    public let specialUse: String?
    public let badgeCount: Int
    public let totalCount: Int

    public init(id: UUID, displayName: String, specialUse: String?, badgeCount: Int, totalCount: Int) {
        self.id = id
        self.displayName = displayName
        self.specialUse = specialUse
        self.badgeCount = badgeCount
        self.totalCount = totalCount
    }
}

/// One account section, cached.
public struct MVMailboxesCachedAccount: Codable, Sendable, Equatable, Identifiable {
    public let id: UUID
    public let name: String
    public let emoji: String?
    public let folders: [MVMailboxesCachedFolder]

    public init(id: UUID, name: String, emoji: String?, folders: [MVMailboxesCachedFolder]) {
        self.id = id
        self.name = name
        self.emoji = emoji
        self.folders = folders
    }
}

/// One unified row, cached.
public struct MVMailboxesCachedUnified: Codable, Sendable, Equatable, Identifiable {
    public let id: UUID
    public let name: String
    public let emoji: String?
    public let unreadCount: Int
    public let contributingAccountEmojis: [String]

    public init(
        id: UUID, name: String, emoji: String?, unreadCount: Int, contributingAccountEmojis: [String]
    ) {
        self.id = id
        self.name = name
        self.emoji = emoji
        self.unreadCount = unreadCount
        self.contributingAccountEmojis = contributingAccountEmojis
    }
}

public struct MVMailboxesCacheSnapshot: Codable, Sendable, Equatable {
    public let unified: [MVMailboxesCachedUnified]
    public let accounts: [MVMailboxesCachedAccount]
    public let savedAt: Date

    public init(unified: [MVMailboxesCachedUnified], accounts: [MVMailboxesCachedAccount], savedAt: Date) {
        self.unified = unified
        self.accounts = accounts
        self.savedAt = savedAt
    }
}

/// Caches accounts, folders and unified views to disk as JSON — A39's own rule ("React Query
/// localStorage persister, adapted"): the same 24-hour max age, and list windows (the actual mail)
/// deliberately excluded, since only the overview's own shape needs to paint before the network
/// answers.
public struct MailboxesDiskCache: Sendable {
    private static let maxAge: TimeInterval = 24 * 3600
    private let fileURL: URL

    /// `directory` is injectable so a test never touches the real Caches directory.
    public init(directory: URL = FileManager.default.temporaryDirectory) {
        self.fileURL = directory.appendingPathComponent("mailboxes-cache.json")
    }

    public func save(_ snapshot: MVMailboxesCacheSnapshot) {
        guard let data = try? JSONEncoder.mvDefault.encode(snapshot) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }

    /// `nil` when there is nothing cached, the file is unreadable, or the cache is older than 24
    /// hours — stale enough that showing it would read as wrong rather than merely out of date.
    public func load(now: Date = Date()) -> MVMailboxesCacheSnapshot? {
        guard let data = try? Data(contentsOf: fileURL),
            let snapshot = try? JSONDecoder.mvDefault.decode(MVMailboxesCacheSnapshot.self, from: data)
        else {
            return nil
        }
        guard now.timeIntervalSince(snapshot.savedAt) < Self.maxAge else { return nil }
        return snapshot
    }
}
