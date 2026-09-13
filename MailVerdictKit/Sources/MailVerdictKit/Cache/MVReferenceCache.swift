import Foundation

/// The app's one copy of the slow-changing data every list and reader page reads — accounts,
/// unified views, and each account's folders and contact-photo index. A screen opening again
/// draws from the last copy at once and then asks for a fresh one; concurrent screens asking for
/// the same thing share one request. Live events that change a kind of data drop it.
@MainActor
public final class MVReferenceCache: LiveEventSubscriber {
    /// How old a copy may be when a caller takes it instead of asking (`folders(accountId:)`,
    /// `photoIndex(accountId:)`). Every list screen fetches fresh on open regardless, which is
    /// what keeps these current in ordinary use.
    public static let reuseAge: TimeInterval = 300

    private let backend: any MVMailListBackend
    private let accountsLoader: MVKeyedLoader<Int, [AccountResponse]>
    private let viewsLoader: MVKeyedLoader<Int, [UnifiedFolderResponse]>
    private let foldersLoader: MVKeyedLoader<UUID, [FolderResponse]>
    private let photoIndexLoader: MVKeyedLoader<UUID, ContactPhotoIndexResponse>

    public init(backend: any MVMailListBackend, now: @escaping @Sendable () -> Date = { Date() }) {
        self.backend = backend
        accountsLoader = MVKeyedLoader(now: now)
        viewsLoader = MVKeyedLoader(now: now)
        foldersLoader = MVKeyedLoader(now: now)
        photoIndexLoader = MVKeyedLoader(now: now)
    }

    // MARK: Last known copies

    public var cachedAccounts: [AccountResponse]? { accountsLoader.cached(0) }
    public var cachedUnifiedViews: [UnifiedFolderResponse]? { viewsLoader.cached(0) }
    public func cachedFolders(accountId: UUID) -> [FolderResponse]? { foldersLoader.cached(accountId) }
    public func cachedPhotoIndex(accountId: UUID) -> ContactPhotoIndexResponse? { photoIndexLoader.cached(accountId) }

    // MARK: Fresh reads — `nil` when the request failed

    public func fetchAccounts() async -> [AccountResponse]? {
        await accountsLoader.fetch(0) { [backend] in try await backend.fetchAccounts() }
    }

    public func fetchUnifiedViews() async -> [UnifiedFolderResponse]? {
        await viewsLoader.fetch(0) { [backend] in try await backend.fetchUnifiedViews() }
    }

    public func fetchFolders(accountId: UUID) async -> [FolderResponse]? {
        await foldersLoader.fetch(accountId) { [backend] in try await backend.fetchFolders(accountId: accountId) }
    }

    public func fetchPhotoIndex(accountId: UUID) async -> ContactPhotoIndexResponse? {
        await photoIndexLoader.fetch(accountId) { [backend] in
            try await backend.fetchContactPhotoIndex(accountId: accountId)
        }
    }

    // MARK: Reused when recent

    public func folders(accountId: UUID) async -> [FolderResponse]? {
        await foldersLoader.value(accountId, maxAge: Self.reuseAge) { [backend] in
            try await backend.fetchFolders(accountId: accountId)
        }
    }

    public func photoIndex(accountId: UUID) async -> ContactPhotoIndexResponse? {
        await photoIndexLoader.value(accountId, maxAge: Self.reuseAge) { [backend] in
            try await backend.fetchContactPhotoIndex(accountId: accountId)
        }
    }

    // MARK: LiveEventSubscriber

    public func apply(_ invalidations: [MVLiveInvalidation]) {
        for invalidation in invalidations {
            switch invalidation {
            case .resync:
                accountsLoader.invalidate()
                viewsLoader.invalidate()
                foldersLoader.invalidate()
                photoIndexLoader.invalidate()
            case .foldersChanged:
                foldersLoader.invalidate()
                viewsLoader.invalidate()
            case .accountsChanged:
                accountsLoader.invalidate()
            default:
                continue
            }
        }
    }
}
