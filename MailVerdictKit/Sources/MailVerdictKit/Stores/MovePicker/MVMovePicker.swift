import Foundation

/// One row of the Move picker.
public struct MVMoveTarget: Identifiable, Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        /// One account's folder.
        case folder(accountId: UUID, folderId: UUID)
        /// A unified view, for a bulk move out of a unified list: the destination is resolved
        /// per account, since each account has its own id for "the same" folder.
        case unifiedView(UnifiedFolderResponse)
    }

    public let id: String
    public let name: String
    public let symbol: String
    public let kind: Kind

    public init(folder: FolderOrderItem, accountId: UUID) {
        id = folder.folderId.uuidString
        name = folderDisplayName(
            imapName: folder.imapName, displayName: folder.displayName, specialUse: folder.specialUse
        )
        symbol = MVSymbols.folderIcon(specialUse: folder.specialUse)
        kind = .folder(accountId: accountId, folderId: folder.folderId)
    }

    public init(unifiedView: UnifiedFolderResponse) {
        id = "unified:" + unifiedView.id.uuidString
        name = [unifiedView.emoji, unifiedView.unifiedName].compactMap { $0 }.joined(separator: " ")
        symbol = MVSymbols.unifiedViewDefault
        kind = .unifiedView(unifiedView)
    }

    /// The folder this target means in `accountId`, or `nil` when a unified view has no member
    /// folder there.
    public func folderId(forAccount accountId: UUID) -> UUID? {
        switch kind {
        case .folder(let owner, let folderId): return owner == accountId ? folderId : nil
        case .unifiedView(let view): return view.folders.first { $0.accountId == accountId }?.folderId
        }
    }
}

public enum MVMovePicker {

    /// The picker's rows: filtered by name as the field is typed, otherwise the account's most
    /// recently used targets first and then everything else in folder order. The folder the
    /// message is already in is never offered — moving there does nothing.
    public static func ordered(
        _ targets: [MVMoveTarget], excludingFolderId: UUID?, recentIds: [String], query: String
    ) -> [MVMoveTarget] {
        let candidates = targets.filter { target in
            guard let excludingFolderId, case .folder(_, let folderId) = target.kind else { return true }
            return folderId != excludingFolderId
        }
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if !needle.isEmpty {
            return candidates.filter { $0.name.lowercased().contains(needle) }
        }
        let byId = Dictionary(candidates.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let recent = recentIds.compactMap { byId[$0] }
        let recentSet = Set(recent.map(\.id))
        return recent + candidates.filter { !recentSet.contains($0.id) }
    }
}

/// The five most recently used move targets per account (port of the web's
/// `mailverdict:recent-move-folders`).
// `@unchecked Sendable`: `UserDefaults` is thread-safe by Apple's documentation, but
// swift-corelibs-foundation does not mark it `Sendable`.
public struct MVRecentMoveTargets: @unchecked Sendable {
    static let key = "mv.recentMoveTargets"
    static let maxRecent = 5

    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// `accountKey` is an account id, or `"unified"` for a unified view's cross-account targets.
    public func recentIds(accountKey: String) -> [String] {
        all()[accountKey] ?? []
    }

    public func record(targetId: String, accountKey: String) {
        var everything = all()
        let current = everything[accountKey] ?? []
        everything[accountKey] = Array(([targetId] + current.filter { $0 != targetId }).prefix(Self.maxRecent))
        if let data = try? JSONEncoder().encode(everything) {
            defaults.set(data, forKey: Self.key)
        }
    }

    private func all() -> [String: [String]] {
        guard let data = defaults.data(forKey: Self.key),
            let decoded = try? JSONDecoder().decode([String: [String]].self, from: data)
        else { return [:] }
        return decoded
    }
}
