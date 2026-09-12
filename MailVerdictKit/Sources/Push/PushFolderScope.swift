import Foundation
import MailVerdictKit

/// One account's folders in the notification scope checklist.
public struct PushFolderGroup: Sendable, Equatable, Identifiable {
    public var id: UUID { accountId }
    public let accountId: UUID
    public let accountName: String
    public let folders: [FolderResponse]

    public init(accountId: UUID, accountName: String, folders: [FolderResponse]) {
        self.accountId = accountId
        self.accountName = accountName
        self.folders = folders
    }
}

/// Which folders raise a notification — the web's `alert-settings.tsx` rules, ported.
///
/// A scope of `nil` means the arrival folders: everything mail arrives in, so not Sent, Drafts,
/// Trash or Junk. Every change that lands back on exactly that set collapses to `nil` again, so a
/// folder created later is included by default rather than silently left out.
public enum PushFolderScope {

    public static func isArrivalFolder(specialUse: String?) -> Bool {
        specialUse == nil || specialUse == "inbox"
    }

    /// Visible folders only, grouped by account in the accounts' own order, Inbox-through-Trash
    /// leading within each account (`MailboxesSupport.leadOrderedFolders`) — the plain `/folders`
    /// list this reads from carries no saved-order concept at all, so that lead sequence always
    /// applies, unconditionally. A folder hidden from the mail view is not one anyone means to
    /// pick here either.
    public static func groups(accounts: [AccountResponse], foldersByAccount: [UUID: [FolderResponse]])
        -> [PushFolderGroup]
    {
        accounts.compactMap { account in
            let folders = MailboxesSupport.leadOrderedFolders((foldersByAccount[account.id] ?? []).filter(\.isVisible))
            return folders.isEmpty
                ? nil : PushFolderGroup(accountId: account.id, accountName: account.name, folders: folders)
        }
    }

    public static func defaultIds(_ groups: [PushFolderGroup]) -> [UUID] {
        groups.flatMap(\.folders).filter { isArrivalFolder(specialUse: $0.specialUse) }.map(\.id)
    }

    public static func enabledIds(scope: [UUID]?, groups: [PushFolderGroup]) -> Set<UUID> {
        Set(scope ?? defaultIds(groups))
    }

    public static func toggling(_ folderId: UUID, on: Bool, scope: [UUID]?, groups: [PushFolderGroup]) -> [UUID]? {
        var enabled = enabledIds(scope: scope, groups: groups)
        if on { enabled.insert(folderId) } else { enabled.remove(folderId) }
        return collapse(enabled, groups: groups)
    }

    /// The account's switch: on ticks its arrival folders, off clears every folder it has.
    public static func settingAccount(
        _ accountId: UUID, on: Bool, scope: [UUID]?, groups: [PushFolderGroup]
    ) -> [UUID]? {
        guard let group = groups.first(where: { $0.accountId == accountId }) else { return scope }
        var enabled = enabledIds(scope: scope, groups: groups)
        if on {
            enabled.formUnion(group.folders.filter { isArrivalFolder(specialUse: $0.specialUse) }.map(\.id))
        } else {
            enabled.subtract(group.folders.map(\.id))
        }
        return collapse(enabled, groups: groups)
    }

    public static func allEnabled(scope: [UUID]?, groups: [PushFolderGroup]) -> Bool {
        let all = groups.flatMap(\.folders).map(\.id)
        return !all.isEmpty && enabledIds(scope: scope, groups: groups).isSuperset(of: all)
    }

    /// Select All, or Deselect All when everything is already ticked.
    public static func togglingAll(scope: [UUID]?, groups: [PushFolderGroup]) -> [UUID]? {
        if allEnabled(scope: scope, groups: groups) { return [] }
        return collapse(Set(groups.flatMap(\.folders).map(\.id)), groups: groups)
    }

    /// `nil` when `enabled` is exactly the default; otherwise the ids in checklist order.
    static func collapse(_ enabled: Set<UUID>, groups: [PushFolderGroup]) -> [UUID]? {
        if enabled == Set(defaultIds(groups)) { return nil }
        let ordered = groups.flatMap(\.folders).map(\.id).filter(enabled.contains)
        // A scope can name a folder that is hidden now; keep it rather than dropping it unasked.
        let hidden = enabled.subtracting(ordered).sorted { $0.uuidString < $1.uuidString }
        return ordered + hidden
    }
}
