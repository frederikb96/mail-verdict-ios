import Foundation

/// The reader's slow-changing reference data — folders (for Trash/Junk/Archive), sender photos,
/// calendars and identities — shared by every page. Folders and photos come from the app-wide
/// `MVReferenceCache` when there is one, so a reader opens on data a list already fetched;
/// without it they are fetched once per reader. A failed fetch is not remembered, so the next
/// page asking tries again.
@MainActor
public final class ReaderLookups {
    private let api: MVApiClient
    private let cache: MVReferenceCache?
    private var folders: [UUID: Task<[FolderResponse]?, Never>] = [:]
    private var photoIndexes: [UUID: Task<ContactPhotoIndexResponse?, Never>] = [:]
    private var calendarsTask: Task<[MVCalendar]?, Never>?
    private var identitiesTask: Task<[IdentityResponse]?, Never>?

    public init(api: MVApiClient, cache: MVReferenceCache? = nil) {
        self.api = api
        self.cache = cache
    }

    /// What a page can be drawn with right now, without waiting — `nil` until the shared cache
    /// holds this account's folders.
    public func cachedFolders(accountId: UUID) -> [FolderResponse]? {
        cache?.cachedFolders(accountId: accountId)
    }

    public func cachedPhotoIndex(accountId: UUID) -> ContactPhotoIndexResponse? {
        cache?.cachedPhotoIndex(accountId: accountId)
    }

    public func folders(accountId: UUID) async -> [FolderResponse] {
        if let cache { return await cache.folders(accountId: accountId) ?? [] }
        let task = folders[accountId] ?? Task { [api] in try? await api.listFolders(accountId: accountId) }
        folders[accountId] = task
        guard let result = await task.value else {
            folders[accountId] = nil
            return []
        }
        return result
    }

    public func specialUse(folderId: UUID, accountId: UUID) async -> String? {
        await folders(accountId: accountId).first { $0.id == folderId }?.specialUse
    }

    public func photoIndex(accountId: UUID) async -> ContactPhotoIndexResponse? {
        if let cache { return await cache.photoIndex(accountId: accountId) }
        let task =
            photoIndexes[accountId] ?? Task { [api] in try? await api.getContactPhotoIndex(accountId: accountId) }
        photoIndexes[accountId] = task
        let result = await task.value
        if result == nil { photoIndexes[accountId] = nil }
        return result
    }

    public func calendars() async -> [MVCalendar] {
        let task = calendarsTask ?? Task { [api] in try? await api.listCalendars() }
        calendarsTask = task
        guard let result = await task.value else {
            calendarsTask = nil
            return []
        }
        return result
    }

    public func identities() async -> [IdentityResponse] {
        let task = identitiesTask ?? Task { [api] in try? await api.listIdentities() }
        identitiesTask = task
        guard let result = await task.value else {
            identitiesTask = nil
            return []
        }
        return result
    }

    public func invalidateFolders() {
        folders = [:]
    }

    public func invalidateCalendarData() {
        calendarsTask = nil
        identitiesTask = nil
    }

    /// The avatar image for a sender, or `nil` for initials. An embedded photo goes through the
    /// reader's own scheme (it needs the app's credential); a third-party photo URL is only in the
    /// index at all once that sender is allowlisted, and is shown only on a message whose images
    /// are allowed — the same gate as the body's own remote images.
    public static func avatarSource(
        for email: String, in index: ContactPhotoIndexResponse?, imagesAllowed: Bool
    ) -> String? {
        guard let entry = index?.byEmail[email.lowercased()] else { return nil }
        if entry.photoUrl.hasPrefix("/") {
            return ReaderPhotoURL.url(contactId: entry.contactId)
        }
        let lower = entry.photoUrl.lowercased()
        guard imagesAllowed, lower.hasPrefix("https://") || lower.hasPrefix("http://") else { return nil }
        return entry.photoUrl
    }
}
