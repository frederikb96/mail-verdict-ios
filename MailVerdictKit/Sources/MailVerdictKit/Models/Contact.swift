import Foundation

// Mirrors mail_verdict/api/schemas.py's contact shapes this app actually uses — composer
// autocomplete and sender-avatar photos. Contacts management screens are out of scope (Freddy's
// scope rules: contacts are used only via the backend, never an iOS Contacts integration), so the
// full ContactResponse/ContactListResponse/create/update shapes are not ported here.

public struct ContactSearchHitOut: ContractModel, Codable, Sendable, Equatable, Identifiable {
    public static let schemaName = "ContactSearchHitOut"
    public enum ContractKeys: String, CodingKey, CaseIterable {
        case contactId = "contact_id", name, email, source
    }
    public typealias CodingKeys = ContractKeys

    public var id: String { "\(contactId)-\(email)" }
    public let contactId: UUID
    public let name: String
    public let email: String
    public let source: String

    public init(contactId: UUID, name: String, email: String, source: String) {
        self.contactId = contactId
        self.name = name
        self.email = email
        self.source = source
    }
}

public struct ContactPhotoIndexEntry: ContractModel, Codable, Sendable, Equatable {
    public static let schemaName = "ContactPhotoIndexEntry"
    public enum ContractKeys: String, CodingKey, CaseIterable {
        case contactId = "contact_id", photoUrl = "photo_url"
    }
    public typealias CodingKeys = ContractKeys

    public let contactId: UUID
    public let photoUrl: String

    public init(contactId: UUID, photoUrl: String) {
        self.contactId = contactId
        self.photoUrl = photoUrl
    }
}

public struct ContactPhotoIndexResponse: ContractModel, Codable, Sendable, Equatable {
    public static let schemaName = "ContactPhotoIndexResponse"
    public enum ContractKeys: String, CodingKey, CaseIterable { case byEmail = "by_email", partial }
    public typealias CodingKeys = ContractKeys

    /// Keyed by lower-cased email address.
    public let byEmail: [String: ContactPhotoIndexEntry]
    @MVDefaulted<MVDefaultFalse> public var partial: Bool

    public init(byEmail: [String: ContactPhotoIndexEntry], partial: Bool = false) {
        self.byEmail = byEmail
        self.partial = partial
    }
}

/// Where `AvatarView` loads a photo from — `ContactPhotoIndexEntry.photoUrl` is never ambiguous
/// (the backend only ever sends one of these two shapes), so a caller derives this once per entry
/// rather than re-parsing the string at every row.
public enum MVAvatarPhotoSource: Hashable, Sendable {
    /// This backend's own `/contacts/:id/photo` — fetched with the app's own credential.
    case embedded(contactId: UUID)
    /// A third party's own address — already checked against the requesting account's
    /// image-allowlist by the photo-index request itself, so the loader fetches it directly, but
    /// deliberately never attaches this backend's credential to someone else's server.
    case remote(URL)
}

extension ContactPhotoIndexEntry {
    /// `nil` only for a malformed `photoUrl`, which the backend never sends.
    public var avatarSource: MVAvatarPhotoSource? {
        if photoUrl.hasPrefix("/") {
            return .embedded(contactId: contactId)
        }
        guard let url = URL(string: photoUrl), url.scheme != nil else { return nil }
        return .remote(url)
    }
}
