import Foundation

/// Which list a saved page belongs to. Grouped and ungrouped rows are different ids, and the
/// unread filter is a different list, so each combination keeps its own page.
public struct MVOfflineListKey: Hashable, Sendable {
    public let scope: ListScope
    public let threaded: Bool
    public let unreadOnly: Bool

    public init(scope: ListScope, threaded: Bool, unreadOnly: Bool) {
        self.scope = scope
        self.threaded = threaded
        self.unreadOnly = unreadOnly
    }

    var fileName: String {
        let list: String
        switch scope {
        case .folder(let accountId, let folderId):
            list = "folder-\(accountId.uuidString.lowercased())-\(folderId.uuidString.lowercased())"
        case .unified(let viewId, _):
            list = "unified-\(viewId.uuidString.lowercased())"
        }
        return "\(list)-\(threaded ? "threaded" : "flat")-\(unreadOnly ? "unread" : "all").json"
    }
}

/// A list page as it was last read from the server.
public struct MVOfflineListPage: Codable, Sendable, Equatable {
    public let rows: [MessageSummary]
    public let hasOlder: Bool
    public let savedAt: Date
}

/// An image a saved conversation shows — an inline part or a sender photo — as last served.
public struct MVOfflineResource: Codable, Sendable, Equatable {
    public let data: Data
    public let mimeType: String
}

/// A conversation as the reader last read it.
public struct MVOfflineConversation: Codable, Sendable, Equatable {
    public let thread: ThreadResponse
    public let savedAt: Date
}

/// Mail kept on the device so it can still be read when the server cannot be reached: the
/// conversations the reader opened most recently with the images they showed, the newest page of
/// the lists visited most recently, and each folder's role (Inbox, Trash, …) so actions read right.
/// Nothing reads it while the server answers; it is the fallback a failed read turns to.
///
/// One JSON file per conversation and per list, under a directory of the caller's choosing (one
/// per server). Each kind is bounded by `Budget` and evicted least recently used first, by the
/// file's modification date, which every save and every read sets. A file that cannot be read —
/// truncated, or written by a newer build — is deleted rather than trusted; this is a cache, and
/// the next read from the server writes it again.
public actor MVOfflineCache {
    public struct Budget: Sendable {
        public var conversations = 100
        public var conversationBytes = 50 * 1024 * 1024
        public var lists = 30
        /// Rows kept per list: two pages, so a list opened offline still scrolls a little.
        public var rowsPerList = 100
        public var resources = 300
        public var resourceBytes = 50 * 1024 * 1024

        public init() {}
    }

    static let formatVersion = 1

    private struct Envelope<Value: Codable>: Codable {
        let version: Int
        let value: Value
    }

    private let conversationsURL: URL
    private let listsURL: URL
    private let resourcesURL: URL
    private let folderRolesURL: URL
    private let root: URL
    private let budget: Budget
    private let now: @Sendable () -> Date
    private var isDiscarded = false

    public init(directory: URL, budget: Budget = Budget(), now: @escaping @Sendable () -> Date = { Date() }) {
        root = directory
        conversationsURL = directory.appendingPathComponent("conversations", isDirectory: true)
        listsURL = directory.appendingPathComponent("lists", isDirectory: true)
        resourcesURL = directory.appendingPathComponent("resources", isDirectory: true)
        folderRolesURL = directory.appendingPathComponent("folder-roles.json")
        self.budget = budget
        self.now = now
    }

    /// `base/<server key>`: one server's mail never shows for another.
    public static func directory(base: URL, serverURL: String) -> URL {
        base.appendingPathComponent(MVServerKey.fileKey(serverURL), isDirectory: true)
    }

    // MARK: Conversations

    public func saveConversation(_ thread: ThreadResponse, for rowId: UUID) {
        guard !thread.messages.isEmpty else { return }
        let saved = MVOfflineConversation(thread: thread, savedAt: now())
        write(saved, to: conversationsURL.appendingPathComponent(Self.fileName(rowId)))
        prune(conversationsURL, maxCount: budget.conversations, maxBytes: budget.conversationBytes)
    }

    public func conversation(for rowId: UUID) -> MVOfflineConversation? {
        read(MVOfflineConversation.self, from: conversationsURL.appendingPathComponent(Self.fileName(rowId)))
    }

    // MARK: Lists

    /// Keeps the first `Budget.rowsPerList` rows; `hasOlder` is true whenever rows were left out.
    public func saveList(_ rows: [MessageSummary], hasOlder: Bool, for key: MVOfflineListKey) {
        guard !rows.isEmpty else { return }
        let kept = Array(rows.prefix(budget.rowsPerList))
        let page = MVOfflineListPage(rows: kept, hasOlder: hasOlder || kept.count < rows.count, savedAt: now())
        write(page, to: listsURL.appendingPathComponent(key.fileName))
        prune(listsURL, maxCount: budget.lists, maxBytes: nil)
    }

    public func list(for key: MVOfflineListKey) -> MVOfflineListPage? {
        read(MVOfflineListPage.self, from: listsURL.appendingPathComponent(key.fileName))
    }

    // MARK: Images

    /// `key` names the resource for the caller (`MVReaderResourceLoader`); file-name safe.
    public func saveResource(_ data: Data, mimeType: String, key: String) {
        write(MVOfflineResource(data: data, mimeType: mimeType), to: resourcesURL.appendingPathComponent("\(key).json"))
        prune(resourcesURL, maxCount: budget.resources, maxBytes: budget.resourceBytes)
    }

    public func resource(key: String) -> MVOfflineResource? {
        read(MVOfflineResource.self, from: resourcesURL.appendingPathComponent("\(key).json"))
    }

    // MARK: Folder roles

    /// Records the role of every folder in one account's full list — and that the others in it
    /// have none, so a folder that lost its role does not keep it here.
    public func saveFolderRoles(from folders: [FolderResponse]) {
        var roles = folderRoles()
        for folder in folders { roles[folder.id] = folder.specialUse }
        write(
            Dictionary(uniqueKeysWithValues: roles.map { ($0.key.uuidString.lowercased(), $0.value) }),
            to: folderRolesURL)
    }

    /// Each known folder's `special_use`, for actions on saved mail when the folders cannot be read.
    public func folderRoles() -> [UUID: String] {
        let stored = read([String: String].self, from: folderRolesURL) ?? [:]
        var roles: [UUID: String] = [:]
        for (key, role) in stored {
            if let id = UUID(uuidString: key) { roles[id] = role }
        }
        return roles
    }

    // MARK: Discarding

    /// Deletes everything and ignores every later save — signing out must not leave mail behind,
    /// and a save already on its way must not write it back.
    public func discard() {
        isDiscarded = true
        try? FileManager.default.removeItem(at: root)
    }

    /// Removes every server's cache under `base`, for when no cache instance is at hand.
    public static func removeAll(under base: URL) {
        try? FileManager.default.removeItem(at: base)
    }

    // MARK: Files

    private static func fileName(_ rowId: UUID) -> String {
        "\(rowId.uuidString.lowercased()).json"
    }

    private func write<Value: Codable>(_ value: Value, to url: URL) {
        guard !isDiscarded else { return }
        let fileManager = FileManager.default
        do {
            try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let data = try JSONEncoder.mvDefault.encode(Envelope(version: Self.formatVersion, value: value))
            try data.write(to: url, options: .atomic)
            touch(url)
        } catch {
            // A copy that could not be written is simply not there offline.
        }
    }

    private func read<Value: Codable>(_ type: Value.Type, from url: URL) -> Value? {
        guard !isDiscarded, let data = try? Data(contentsOf: url) else { return nil }
        guard let envelope = try? JSONDecoder.mvDefault.decode(Envelope<Value>.self, from: data),
            envelope.version <= Self.formatVersion
        else {
            try? FileManager.default.removeItem(at: url)
            return nil
        }
        touch(url)
        return envelope.value
    }

    /// Recency is the modification date, set from the injected clock so eviction order never
    /// depends on the file system's timestamp resolution.
    private func touch(_ url: URL) {
        try? FileManager.default.setAttributes([.modificationDate: now()], ofItemAtPath: url.path)
    }

    /// Keeps the most recently used files that fit both bounds; a file too big to fit is dropped
    /// even when it is the newest.
    private func prune(_ directory: URL, maxCount: Int, maxBytes: Int?) {
        let fileManager = FileManager.default
        guard let names = try? fileManager.contentsOfDirectory(atPath: directory.path) else { return }
        let files: [(url: URL, date: Date, size: Int)] = names.compactMap { name in
            let url = directory.appendingPathComponent(name)
            guard let attributes = try? fileManager.attributesOfItem(atPath: url.path) else { return nil }
            let date = attributes[.modificationDate] as? Date ?? .distantPast
            let size = (attributes[.size] as? NSNumber)?.intValue ?? 0
            return (url, date, size)
        }
        var keptCount = 0
        var keptBytes = 0
        for file in files.sorted(by: { $0.date > $1.date }) {
            let fits = keptCount < maxCount && (maxBytes.map { keptBytes + file.size <= $0 } ?? true)
            if fits {
                keptCount += 1
                keptBytes += file.size
            } else {
                try? fileManager.removeItem(at: file.url)
            }
        }
    }
}
