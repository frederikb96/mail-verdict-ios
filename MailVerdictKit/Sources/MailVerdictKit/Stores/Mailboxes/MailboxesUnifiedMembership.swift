import Foundation

/// The `MVUnifiedViewMembershipLookup` conformer `MailboxesStore` hands `MVMessagePlaceResolver`.
///
/// `MVUnifiedViewMembershipLookup` is a plain `Sendable` protocol, not `@MainActor` — its one
/// requirement is a synchronous, callable-from-anywhere lookup — while `MailboxesStore` itself is
/// `@MainActor`, so the store cannot conform directly (that conformance would "cross into main
/// actor-isolated code", which Swift 6 refuses). This type is the store's own lock-protected
/// snapshot instead: `MailboxesStore` calls `update(from:)` every time it loads, and this answers
/// the protocol requirement off the main actor, at whatever moment a push tap or a bell row needs
/// it resolved.
public final class MailboxesUnifiedMembership: MVUnifiedViewMembershipLookup, @unchecked Sendable {
    private let lock = NSLock()
    private var views: [(id: UUID, name: String, folderIds: Set<UUID>)] = []
    private let recentViews: MVRecentViewRecord

    public init(recentViews: MVRecentViewRecord = MVRecentViewRecord()) {
        self.recentViews = recentViews
    }

    public func update(from unifiedFolders: [UnifiedFolderResponse]) {
        let mapped = unifiedFolders.map {
            (id: $0.id, name: $0.unifiedName, folderIds: Set($0.folders.map(\.folderId)))
        }
        lock.lock()
        views = mapped
        lock.unlock()
    }

    public func mostRecentUnifiedView(containingFolderId folderId: UUID) -> MVUnifiedViewRef? {
        lock.lock()
        let current = views
        lock.unlock()
        return MailboxesSupport.mostRecentUnifiedView(
            among: current, recentRefs: recentViews.recentUnifiedViews(), containingFolderId: folderId
        )
    }
}
