import Foundation

/// Which folder or unified view a list screen is showing.
public enum ListScope: Hashable, Codable, Sendable {
    case folder(accountId: UUID, folderId: UUID)
    /// `name` is what `MVApiClient.listUnifiedMessages(viewName:)` actually takes — the backend
    /// addresses a unified view by name, not id, the same way the web's own mail URL does (see
    /// `unified.py`'s own docstring: "a view is addressed by its name"). Carried here too so a
    /// persisted route surviving a rename still shows the right title until the next refetch.
    case unified(viewId: UUID, name: String)
}

/// Where a reader page's conversation came from — which list it pages through, and what the
/// Options menu's "Show in Folder" resolves against.
public struct ReaderContext: Hashable, Codable, Sendable {
    public enum Source: Hashable, Codable, Sendable {
        case list(ListScope)
        case search(SearchContext)
        case spamReview
    }

    public let source: Source
    public let messageId: UUID

    public init(source: Source, messageId: UUID) {
        self.source = source
        self.messageId = messageId
    }
}

/// The minimal identity needed to re-issue the same search and page through its results in the
/// same order — not the search screen's own UI state (which chip is expanded, and so on), which
/// stays that screen's own store's concern. A `Codable` value type rather than a dependency on
/// that store's type, so this package's navigation layer does not wait on the search block to
/// exist.
public struct SearchContext: Hashable, Codable, Sendable {
    public enum Mode: String, Hashable, Codable, Sendable { case text, semantic }
    public enum Sort: String, Hashable, Codable, Sendable { case relevance, chronological }

    public let mode: Mode
    public let query: String
    public let accountId: UUID?
    /// `nil` means every folder; `[]` means search nothing — the same distinction the Folders
    /// sheet makes.
    public let folderIds: [UUID]?
    public let fields: [MVSearchField]?
    public let strictness: MVSemanticStrictness?
    public let sort: Sort
    public let receivedAfter: Date?
    public let receivedBefore: Date?

    public init(
        mode: Mode, query: String, accountId: UUID? = nil, folderIds: [UUID]? = nil,
        fields: [MVSearchField]? = nil, strictness: MVSemanticStrictness? = nil,
        sort: Sort = .relevance, receivedAfter: Date? = nil, receivedBefore: Date? = nil
    ) {
        self.mode = mode
        self.query = query
        self.accountId = accountId
        self.folderIds = folderIds
        self.fields = fields
        self.strictness = strictness
        self.sort = sort
        self.receivedAfter = receivedAfter
        self.receivedBefore = receivedBefore
    }
}

/// A pushed destination on the app's one `NavigationStack`. Persisted across relaunch (see
/// `MVPersistedPath`) — every case is `Codable` for exactly that reason.
public enum Route: Hashable, Codable, Sendable {
    case list(ListScope, aroundMessageId: UUID?)
    case reader(ReaderContext)
    case search(initialQuery: String?)
    case spamReview
    case notifications
    case settings
    case settingsCategory(String)
    case unifiedViews
    case accountOrder
    case notificationSettings
    case accounts
    case account(UUID)
    case folderOrder(UUID)
    case imageExceptions(UUID)
    case identities(UUID)
}
