import Foundation

/// Connection health for one account's header chip — a port of the web's `accountConnectionState`
/// (`ui/src/hooks/use-sync-status.ts`): PostIMAP retries a failed account unboundedly, so
/// `state == "error"` alone means "having a bad time", not "dead". Whether a full sync has ever
/// completed is what tells the two apart.
public enum MVAccountConnectionState: Sendable, Equatable {
    case ok
    case retrying
    case neverConnected
}

public enum MailboxesSupport {

    public static func connectionState(accountState: String, lastFullSync: Date?) -> MVAccountConnectionState {
        guard accountState == "error" else { return .ok }
        return lastFullSync != nil ? .retrying : .neverConnected
    }

    /// Visible folders in the order `GET /folder-order` already resolved (a saved custom order, or
    /// alphabetical when none was ever saved — the server's own fallback), with INBOX forced to
    /// lead regardless: that alphabetical fallback buries INBOX behind anything starting with a
    /// letter before "I". Port of the web's own `orderedFolders` in `app-sidebar.tsx`.
    public static func orderFolders(_ items: [FolderOrderItem]) -> [FolderOrderItem] {
        let visible = items.filter(\.isVisible)
        guard let inboxIndex = visible.firstIndex(where: { $0.specialUse == "inbox" }), inboxIndex > 0
        else { return visible }
        var reordered = visible
        let inbox = reordered.remove(at: inboxIndex)
        reordered.insert(inbox, at: 0)
        return reordered
    }

    /// The badge a folder row shows — Drafts never carries an unread state, so the total stands in
    /// for it. Port of the web's `getFolderBadgeCount`.
    public static func folderBadgeCount(specialUse: String?, unreadCount: Int, totalCount: Int) -> Int {
        specialUse == "drafts" ? totalCount : unreadCount
    }

    /// Which accounts feed a merged unified folder, in first-seen order, deduplicated — port of
    /// the web's `getContributingAccounts`.
    public static func contributingAccounts(
        for view: UnifiedFolderResponse, accounts: [AccountResponse]
    ) -> [AccountResponse] {
        var seen = Set<UUID>()
        var result: [AccountResponse] = []
        for source in view.folders {
            guard !seen.contains(source.accountId) else { continue }
            seen.insert(source.accountId)
            if let account = accounts.first(where: { $0.id == source.accountId }) {
                result.append(account)
            }
        }
        return result
    }

    /// Distinct account names among a set of dead-outbox rows, in first-seen order — port of the
    /// web's `Array.from(new Set(dead.map(...))).map(...).filter(...)` in `outbox-dead-banner.tsx`,
    /// silently skipping an id with no matching account the same way.
    public static func distinctAccountNames(
        forAccountIds accountIds: [UUID], accounts: [AccountResponse]
    ) -> [String] {
        var seen = Set<UUID>()
        var names: [String] = []
        for id in accountIds {
            guard !seen.contains(id) else { continue }
            seen.insert(id)
            if let account = accounts.first(where: { $0.id == id }) {
                names.append(account.name)
            }
        }
        return names
    }

    /// The dead-outbox banner text, or `nil` when there is nothing to show — port of
    /// `outbox-dead-banner.tsx`. Pass an empty `accountNames` from a scope that is already known
    /// to be one account, where naming "this account" reads better than repeating its name.
    public static func deadOutboxBannerText(messageCount: Int, accountNames: [String]) -> String? {
        guard messageCount > 0 else { return nil }
        let plural = messageCount > 1 ? "s" : ""
        let target = accountNames.isEmpty ? "this account" : accountNames.joined(separator: ", ")
        return "\(messageCount) message\(plural) could not be sent — check SMTP settings on \(target)."
    }

    /// Whether a batch of live invalidations means this screen's data is stale — UX design §2.1's
    /// own "Live" rule: `folder.changed`, `account.changed` and a resync. `mail.*` counts are
    /// folded into `folderSynced`/`mailNew` etc, all of which leave folder and unread counts
    /// stale the same way `foldersChanged` does.
    public static func shouldReload(for invalidations: [MVLiveInvalidation]) -> Bool {
        invalidations.contains {
            switch $0 {
            case .resync, .foldersChanged, .accountsChanged, .folderSynced, .mailNew, .mailUpdated, .mailDeleted:
                return true
            default:
                return false
            }
        }
    }

    /// Among every unified view containing this folder, the one opened most recently — falling
    /// back to the first one found when none of the recently opened views match, which is what
    /// keeps this total rather than `nil` the moment the relevant view has aged out of the
    /// 5-entry recency list `MVRecentViewRecord` keeps. A free function rather than a method on
    /// `MailboxesStore`: it touches no actor state, and `MailboxesUnifiedMembership` (the
    /// `MVUnifiedViewMembershipLookup` conformer, which must stay off the main actor to satisfy
    /// that protocol's own `Sendable` requirement) needs this exact logic too.
    public static func mostRecentUnifiedView(
        among views: [(id: UUID, name: String, folderIds: Set<UUID>)], recentRefs: [MVUnifiedViewRef],
        containingFolderId folderId: UUID
    ) -> MVUnifiedViewRef? {
        let candidates = views.filter { $0.folderIds.contains(folderId) }
        guard !candidates.isEmpty else { return nil }
        for ref in recentRefs {
            if let match = candidates.first(where: { $0.id == ref.id }) {
                return MVUnifiedViewRef(id: match.id, name: match.name)
            }
        }
        guard let first = candidates.first else { return nil }
        return MVUnifiedViewRef(id: first.id, name: first.name)
    }
}
