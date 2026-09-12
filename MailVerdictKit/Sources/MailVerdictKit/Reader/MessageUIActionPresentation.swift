import Foundation

/// What the reader's Options menu adds to the shared action wording (`MessageUIActionTitle`): the
/// remote-images choices name the sender and domain they apply to, and the verdict group has a
/// heading.
extension MVMessageUIAction {

    /// `title`, except the remote-images choices, which read "Always Load from {sender}" and
    /// "Always Load from @{domain}" once the sender is known.
    public func readerTitle(senderEmail: String, senderDomain: String) -> String {
        switch self {
        case .alwaysLoadFromSender where !senderEmail.isEmpty: return "Always Load from \(senderEmail)"
        case .alwaysLoadFromDomain where !senderDomain.isEmpty: return "Always Load from @\(senderDomain)"
        default: return title
        }
    }

    /// The remote-images choices, shown together as one submenu.
    public var isRemoteImagesChoice: Bool {
        self == .loadImagesOnce || self == .alwaysLoadFromSender || self == .alwaysLoadFromDomain
    }

    /// The verdict group's heading — "Classified as spam by {model}" or "Classified as not spam".
    public static func verdictGroupTitle(_ verdict: MVMessageVerdictContext) -> String {
        guard verdict.isSpam else { return "Classified as not spam" }
        return verdict.modelUsed.map { "Classified as spam by \($0)" } ?? "Classified as spam"
    }
}
