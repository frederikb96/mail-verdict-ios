import Foundation

/// Collapse state and the top-visible-row anchor, both surviving a relaunch, so coming back from
/// a folder or unified view restores exactly this. Kept as a plain `UserDefaults`-backed type
/// rather than folded into `MailboxesStore` itself, so both halves have their own direct test
/// without constructing the whole store's networking.
// `@unchecked Sendable`: `UserDefaults` is thread-safe by Apple's own documentation, but
// swift-corelibs-foundation does not mark it `Sendable` — asserted by hand, the same shape
// `MVRecentViewRecord` already uses. Every member reads or writes `defaults` directly rather than
// through a settable computed property, so none of them need `mutating` — the same reason this can
// sit behind a `let` in `MailboxesStore`.
public struct MailboxesUIState: @unchecked Sendable {
    private static let collapsedKey = "mv.mailboxes.collapsed"
    private static let anchorKey = "mv.mailboxes.topVisibleRowId"

    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// Keys are `"unified"` for the Unified section, `"account:<id>"` for an account section.
    public static func unifiedKey() -> String { "unified" }
    public static func accountKey(_ accountId: UUID) -> String { "account:\(accountId)" }

    public func isCollapsed(_ key: String) -> Bool {
        (defaults.stringArray(forKey: Self.collapsedKey) ?? []).contains(key)
    }

    public func setCollapsed(_ isCollapsed: Bool, forKey key: String) {
        var set = Set(defaults.stringArray(forKey: Self.collapsedKey) ?? [])
        if isCollapsed { set.insert(key) } else { set.remove(key) }
        defaults.set(Array(set), forKey: Self.collapsedKey)
    }

    /// The identity of the row that was at the top of the viewport — `"unified:<id>"` or
    /// `"folder:<id>"`, matching `MailboxesUnifiedRow.anchorId`/`MailboxesFolderRow.anchorId`.
    /// `nil` means "scroll to the very top", which is also the state before anything has ever
    /// been recorded.
    public func topVisibleRowId() -> String? {
        defaults.string(forKey: Self.anchorKey)
    }

    public func setTopVisibleRowId(_ id: String?) {
        defaults.set(id, forKey: Self.anchorKey)
    }
}
