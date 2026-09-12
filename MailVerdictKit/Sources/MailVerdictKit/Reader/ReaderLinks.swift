import Foundation

/// A control in the reader's page chrome. Page script is off, so every button in the page is an
/// `mv://` link the navigation delegate intercepts, cancels and handles natively.
public enum MVReaderLink: Sendable, Equatable {
    public enum AddressField: String, Sendable, Equatable { case from, to, cc }
    public enum ImageChoice: String, Sendable, Equatable { case once, sender, domain }

    case address(messageId: UUID, field: AddressField, index: Int)
    case attachment(messageId: UUID, attachmentId: UUID)
    case shareAttachment(messageId: UUID, attachmentId: UUID)
    case images(messageId: UUID, choice: ImageChoice)
    case draft(messageId: UUID)
    case retry
    case invitation(messageId: UUID, action: MVInvitationLinkAction)

    public static let scheme = "mv"

    public var url: String {
        switch self {
        case .address(let id, let field, let index): return "mv://address/\(Self.id(id))/\(field.rawValue)/\(index)"
        case .attachment(let id, let att): return "mv://attachment/\(Self.id(id))/\(Self.id(att))"
        case .shareAttachment(let id, let att): return "mv://share-attachment/\(Self.id(id))/\(Self.id(att))"
        case .images(let id, let choice): return "mv://images/\(Self.id(id))/\(choice.rawValue)"
        case .draft(let id): return "mv://draft/\(Self.id(id))"
        case .retry: return "mv://retry"
        case .invitation(let id, let action): return "mv://invitation/\(Self.id(id))/\(action.pathComponent)"
        }
    }

    public init?(url: URL) {
        guard url.scheme?.lowercased() == Self.scheme, let host = url.host?.lowercased() else { return nil }
        let parts = url.path.split(separator: "/").map(String.init)
        func uuid(_ index: Int) -> UUID? { index < parts.count ? UUID(uuidString: parts[index]) : nil }

        switch host {
        case "address":
            guard let id = uuid(0), parts.count == 3, let field = AddressField(rawValue: parts[1]),
                let index = Int(parts[2])
            else { return nil }
            self = .address(messageId: id, field: field, index: index)
        case "attachment", "share-attachment":
            guard let id = uuid(0), let att = uuid(1) else { return nil }
            self =
                host == "attachment"
                ? .attachment(messageId: id, attachmentId: att) : .shareAttachment(messageId: id, attachmentId: att)
        case "images":
            guard let id = uuid(0), parts.count == 2, let choice = ImageChoice(rawValue: parts[1]) else { return nil }
            self = .images(messageId: id, choice: choice)
        case "draft":
            guard let id = uuid(0) else { return nil }
            self = .draft(messageId: id)
        case "retry":
            self = .retry
        case "invitation":
            guard let id = uuid(0), let action = MVInvitationLinkAction(pathComponents: Array(parts.dropFirst()))
            else { return nil }
            self = .invitation(messageId: id, action: action)
        default:
            return nil
        }
    }

    private static func id(_ uuid: UUID) -> String { uuid.uuidString.lowercased() }
}

/// A control on the invitation card.
public enum MVInvitationLinkAction: Sendable, Equatable {
    case addToCalendar
    case toggleAlwaysUse
    case respond(RespondRequest.Reply)
    case sendAgain
    case note
    case eventDetails
    case confirmChange
    case retry

    var pathComponent: String {
        switch self {
        case .addToCalendar: return "add"
        case .toggleAlwaysUse: return "always-use"
        case .respond(let reply): return "respond/\(reply.rawValue)"
        case .sendAgain: return "send-again"
        case .note: return "note"
        case .eventDetails: return "details"
        case .confirmChange: return "confirm"
        case .retry: return "retry"
        }
    }

    init?(pathComponents parts: [String]) {
        switch parts.first {
        case "add": self = .addToCalendar
        case "always-use": self = .toggleAlwaysUse
        case "respond":
            guard parts.count == 2, let reply = RespondRequest.Reply(rawValue: parts[1]) else { return nil }
            self = .respond(reply)
        case "send-again": self = .sendAgain
        case "note": self = .note
        case "details": self = .eventDetails
        case "confirm": self = .confirmChange
        case "retry": self = .retry
        default: return nil
        }
    }
}

/// What a navigation the page asked for means — decided here so the web view delegate only
/// dispatches.
public enum MVReaderNavigation: Sendable, Equatable {
    /// The reader's own document load.
    case allow
    case control(MVReaderLink)
    case web(URL)
    case mailto(URL)
    /// An in-page `#fragment` link, typically a newsletter's own table of contents.
    case anchor(String)
    case ignore

    public static func classify(_ url: URL, isUserAction: Bool) -> MVReaderNavigation {
        let scheme = url.scheme?.lowercased() ?? ""
        switch scheme {
        case MVReaderLink.scheme:
            return MVReaderLink(url: url).map(MVReaderNavigation.control) ?? .ignore
        case "http", "https":
            return isUserAction ? .web(url) : .ignore
        case "mailto":
            return isUserAction ? .mailto(url) : .ignore
        case "about":
            if let fragment = url.fragment, !fragment.isEmpty, isUserAction { return .anchor(fragment) }
            return isUserAction ? .ignore : .allow
        default:
            return .ignore
        }
    }
}
