import Foundation

/// A unified view, named rather than merely identified — everywhere this package needs to
/// address one (`ListScope.unified`, the recent-views record below) takes exactly these two
/// fields, never the full `UnifiedFolderResponse`, since nothing here cares about its folders.
public struct MVUnifiedViewRef: Codable, Hashable, Sendable {
    public let id: UUID
    public let name: String

    public init(id: UUID, name: String) {
        self.id = id
        self.name = name
    }
}

/// Which unified views contain a given folder — implemented by whichever store holds the live
/// `GET /api/unified/folders` data (the Mailboxes screen's own), so `MVMessagePlaceResolver`
/// itself never fetches or caches folder membership.
public protocol MVUnifiedViewMembershipLookup: Sendable {
    /// The most recently opened unified view containing this folder, or `nil` if none of the
    /// caller's known views do.
    func mostRecentUnifiedView(containingFolderId folderId: UUID) -> MVUnifiedViewRef?
}

/// Persists "was the last mail view a unified one" plus up to 5 recently opened unified views,
/// kept by `MessagePlaceResolver` so a deep link opens in the same kind of view the person was
/// last looking at rather than always falling back to the message's own folder.
// `@unchecked Sendable`: `UserDefaults` is thread-safe by Apple's own documentation, but
// swift-corelibs-foundation does not mark it `Sendable`, so the package (built on Linux too)
// asserts it by hand rather than inheriting whatever the platform's own annotation happens to be.
public struct MVRecentViewRecord: @unchecked Sendable {
    private static let lastViewWasUnifiedKey = "mv.lastViewWasUnified"
    private static let recentUnifiedViewsKey = "mv.recentUnifiedViews"
    private static let maxRecent = 5

    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public var lastViewWasUnified: Bool {
        defaults.bool(forKey: Self.lastViewWasUnifiedKey)
    }

    public func recordFolderView() {
        defaults.set(false, forKey: Self.lastViewWasUnifiedKey)
    }

    public func recordUnifiedView(_ ref: MVUnifiedViewRef) {
        defaults.set(true, forKey: Self.lastViewWasUnifiedKey)
        var recent = recentUnifiedViews()
        recent.removeAll { $0.id == ref.id }
        recent.insert(ref, at: 0)
        if recent.count > Self.maxRecent { recent = Array(recent.prefix(Self.maxRecent)) }
        if let data = try? JSONEncoder().encode(recent) {
            defaults.set(data, forKey: Self.recentUnifiedViewsKey)
        }
    }

    public func recentUnifiedViews() -> [MVUnifiedViewRef] {
        guard let data = defaults.data(forKey: Self.recentUnifiedViewsKey),
            let refs = try? JSONDecoder().decode([MVUnifiedViewRef].self, from: data)
        else {
            return []
        }
        return refs
    }
}

public enum MVMessagePlaceResolution: Sendable, Equatable {
    case route([Route])
    case notFound(toastMessage: String)
}

/// Where a message is now, and the path to it — the one place push taps, bell rows and search's
/// "Show in Folder" all resolve "open this message" through, so the three never drift into
/// different answers for the same question.
public struct MVMessagePlaceResolver: Sendable {
    private let apiClient: MVApiClient
    private let recentViews: MVRecentViewRecord
    private let membershipLookup: (any MVUnifiedViewMembershipLookup)?

    public init(
        apiClient: MVApiClient, recentViews: MVRecentViewRecord = MVRecentViewRecord(),
        membershipLookup: (any MVUnifiedViewMembershipLookup)? = nil
    ) {
        self.apiClient = apiClient
        self.recentViews = recentViews
        self.membershipLookup = membershipLookup
    }

    public func resolve(messageId: UUID) async -> MVMessagePlaceResolution {
        guard let location = try? await apiClient.locateMessage(id: messageId) else {
            return .notFound(toastMessage: "That message no longer exists")
        }
        let scope = Self.resolveScope(
            location: location, lastViewWasUnified: recentViews.lastViewWasUnified,
            membership: membershipLookup
        )
        let context = ReaderContext(source: .list(scope), messageId: messageId)
        return .route([.list(scope, aroundMessageId: messageId), .reader(context)])
    }

    /// Pure and internal, so the "unified vs. own folder" choice has its own direct test rather
    /// than only being reachable through a real `locateMessage` network call.
    static func resolveScope(
        location: MessageLocation, lastViewWasUnified: Bool,
        membership: (any MVUnifiedViewMembershipLookup)?
    ) -> ListScope {
        if lastViewWasUnified, let ref = membership?.mostRecentUnifiedView(containingFolderId: location.folderId) {
            return .unified(viewId: ref.id, name: ref.name)
        }
        return .folder(accountId: location.accountId, folderId: location.folderId)
    }
}
