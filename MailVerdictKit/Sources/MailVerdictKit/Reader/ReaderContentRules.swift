import Foundation

/// The content rule lists a message page loads under. Everything remote is blocked except the
/// reader's own schemes and inline `data:` images; a page whose document may show remote images
/// gets the second list, which lets images (and only images) through.
///
/// The backend already strips remote images for every sender not on the allowlist, so this is
/// defence in depth — it is what stops a stylesheet font, a CSS `url()` the server missed, or a
/// prefetch from ever reaching the network.
public enum ReaderContentRules {

    public static let strictIdentifier = "mv-reader-strict"
    public static let imagesAllowedIdentifier = "mv-reader-images-allowed"

    public static var strict: String { encode(baseRules()) }

    public static var imagesAllowed: String {
        encode(
            baseRules() + [["trigger": ["url-filter": "^https?://", "resource-type": ["image"]], "action": ignore()]])
    }

    private static func ignore() -> [String: Any] { ["type": "ignore-previous-rules"] }

    private static func baseRules() -> [[String: Any]] {
        [
            ["trigger": ["url-filter": ".*"], "action": ["type": "block"]],
            ["trigger": ["url-filter": "^\(MessageBodyRenderer.attachmentScheme):"], "action": ignore()],
            ["trigger": ["url-filter": "^\(ReaderPhotoURL.scheme):"], "action": ignore()],
            ["trigger": ["url-filter": "^data:"], "action": ignore()],
            ["trigger": ["url-filter": "^about:"], "action": ignore()],
        ]
    }

    private static func encode(_ rules: [[String: Any]]) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: rules, options: [.sortedKeys]) else {
            return "[]"
        }
        return String(decoding: data, as: UTF8.self)
    }
}

/// A sender avatar's photo URL inside a page — the backend's same-origin photo endpoint needs the
/// app's credential, so the page asks the reader's scheme handler for it instead.
public enum ReaderPhotoURL {
    public static let scheme = "mv-photo"

    public static func url(contactId: UUID) -> String {
        "\(scheme)://contact/\(contactId.uuidString.lowercased())"
    }

    public static func contactId(from url: URL) -> UUID? {
        guard url.scheme?.lowercased() == scheme, url.host?.lowercased() == "contact" else { return nil }
        return UUID(uuidString: url.lastPathComponent)
    }
}
