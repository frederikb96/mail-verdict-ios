import Foundation

/// Which list the rows on screen are. Any change here is a different list — it starts at the top
/// rather than inheriting the previous list's offset, clamped to a different height.
public struct MVListIdentity: Hashable, Sendable {
    public let scope: ListScope
    public let threaded: Bool
    public let unreadOnly: Bool
    /// The quick filter's effective query; empty when not filtering.
    public let filterQuery: String
    /// Bumped whenever the rows are replaced by a fresh read of otherwise the same list — a jump
    /// to the newest mail, or a whole-folder action.
    public let generation: Int

    public init(scope: ListScope, threaded: Bool, unreadOnly: Bool, filterQuery: String, generation: Int) {
        self.scope = scope
        self.threaded = threaded
        self.unreadOnly = unreadOnly
        self.filterQuery = filterQuery
        self.generation = generation
    }
}

/// Grouping by conversation is one global preference, persisted, on by default — the web's own
/// `threadedViewAtom`.
public enum MVListPreferences {
    static let threadedKey = "mv.threaded"

    public static func threaded(defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: threadedKey) as? Bool ?? true
    }

    public static func setThreaded(_ threaded: Bool, defaults: UserDefaults = .standard) {
        defaults.set(threaded, forKey: threadedKey)
    }
}

/// State that outlives one list screen but not the app session: the unread filter is kept per
/// list, so leaving a list and coming back finds it as it was, while a relaunch starts unfiltered.
@MainActor
public final class MVListSession {
    public static let shared = MVListSession()

    private var unreadOnlyByScope: [ListScope: Bool] = [:]

    public init() {}

    public func unreadOnly(for scope: ListScope) -> Bool {
        unreadOnlyByScope[scope] ?? false
    }

    public func setUnreadOnly(_ unreadOnly: Bool, for scope: ListScope) {
        unreadOnlyByScope[scope] = unreadOnly
    }
}

/// The last reading position per list, across relaunches — restored through a window around the
/// anchor row, since that row is rarely on the newest page.
// `@unchecked Sendable`: `UserDefaults` is thread-safe by Apple's documentation, but
// swift-corelibs-foundation does not mark it `Sendable`.
public struct MVListPositionStore: @unchecked Sendable {
    public struct Position: Codable, Equatable, Sendable {
        public let anchor: MVListAnchor
        /// At the very top of a window that starts at the newest message — a relaunch then opens
        /// at the newest edge rather than around an old row.
        public let atTop: Bool

        public init(anchor: MVListAnchor, atTop: Bool) {
            self.anchor = anchor
            self.atTop = atTop
        }
    }

    static let key = "mv.listPositions"

    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public func load(scope: ListScope, threaded: Bool) -> Position? {
        all()[Self.entryKey(scope: scope, threaded: threaded)]
    }

    public func save(_ position: Position?, scope: ListScope, threaded: Bool) {
        var everything = all()
        everything[Self.entryKey(scope: scope, threaded: threaded)] = position
        if let data = try? JSONEncoder().encode(everything) {
            defaults.set(data, forKey: Self.key)
        }
    }

    /// Grouped and ungrouped rows are different ids for the same folder, so each keeps its own.
    static func entryKey(scope: ListScope, threaded: Bool) -> String {
        let suffix = threaded ? "threaded" : "flat"
        switch scope {
        case .folder(let accountId, let folderId):
            return "folder:\(accountId.uuidString):\(folderId.uuidString):\(suffix)"
        case .unified(let viewId, _):
            return "unified:\(viewId.uuidString):\(suffix)"
        }
    }

    private func all() -> [String: Position] {
        guard let data = defaults.data(forKey: Self.key),
            let decoded = try? JSONDecoder().decode([String: Position].self, from: data)
        else { return [:] }
        return decoded
    }
}

/// Where the controller should put the reader once the first page of a list has landed.
public enum MVListLanding: Equatable, Sendable {
    /// A message opened from outside the list (a notification, "Show in Folder"): its row a
    /// third of the way down the screen.
    case revealInUpperThird(UUID)
    /// A relaunch: the saved anchor, exactly.
    case restore(MVListAnchor)
}

public enum MVListPhase: Equatable, Sendable {
    case loading
    case loaded
    case failed(String)
}

/// What the list knows about where it is — folder and account metadata for the title, subtitle,
/// per-row folder roles and banners. Everything here is optional: a list shows its rows before
/// any of it arrives.
public struct MVListContext: Equatable, Sendable {
    public var accounts: [UUID: AccountResponse] = [:]
    public var folders: [UUID: FolderResponse] = [:]
    public var unifiedView: UnifiedFolderResponse?
    /// Set when the list's account is in error and has never completed a full sync — the web's
    /// `never_connected` state, shown in place of the list.
    public var neverConnectedError: String?
    public var deadOutboxCount = 0
    public var deadOutboxAccountNames: [String] = []
    /// Contact photos by lower-cased sender address, from each account's photo index.
    public var avatarPhotos: [String: MVAvatarPhotoSource] = [:]

    public init() {}
}
