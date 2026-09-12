import Foundation

/// A file attached to the message as a chip — picked from Photos or Files, carried over from a
/// forwarded original, or given back by Undo Send.
public struct ComposeAttachment: Identifiable, Equatable, Sendable, Codable {
    public let id: UUID
    public let filename: String
    public let contentType: String?
    public let data: Data

    public init(id: UUID = UUID(), filename: String, contentType: String?, data: Data) {
        self.id = id
        self.filename = filename
        self.contentType = contentType
        self.data = data
    }

    public var sizeBytes: Int { data.count }
}

/// An image shown inside the body, sent as an inline attachment the body references by
/// `cid:<contentId>`.
public struct ComposeInlineImage: Equatable, Sendable, Codable {
    public let contentId: String
    public let filename: String
    public let contentType: String?
    public let data: Data

    public init(contentId: String, filename: String, contentType: String?, data: Data) {
        self.contentId = contentId
        self.filename = filename
        self.contentType = contentType
        self.data = data
    }
}

public enum ComposeContentId {
    /// Unique within a message is all a content id needs; a UUID gives that without a counter
    /// anyone has to keep.
    public static func make() -> String {
        "img" + UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
    }
}
