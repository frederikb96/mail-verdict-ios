import Foundation

/// What the share sheet may ask of the phone and the server before anything is sent.
///
/// The byte limits mirror the server's configured defaults (`max_file_bytes`,
/// `max_attachment_bytes`, `max_attachments`). They exist so an obvious refusal is shown before
/// an upload, not to replace the server's answer, which stays the authority.
public enum ShareLimits {
    /// One file, for an order or for a mail.
    public static let maxFileBytes = 26_214_400
    /// Everything on one draft. Below the server's per-message cap because the multipart body is
    /// built in memory, next to the files it carries, inside an extension's small memory budget.
    public static let maxDraftBytes = 33_554_432
    public static let maxDraftFiles = 20
    /// Images going to Orders are fitted to this long edge: a ticket or an invoice stays readable
    /// and the upload stays small.
    public static let ordersImageLongEdge: Double = 2_000
}

/// One file ready to send.
public struct ShareFile: Sendable, Equatable {
    public let filename: String
    public let contentType: String
    public let data: Data

    public init(filename: String, contentType: String, data: Data) {
        self.filename = filename
        self.contentType = contentType
        self.data = data
    }
}

/// How an image is fitted for where it is going.
public enum ShareFitPolicy: Sendable, Equatable {
    case orders
    case draft
}

/// One shared item on its way out.
///
/// `prepare` produces the bytes at send time, so a batch of large files is never in memory at
/// once; `id` makes a retry skip what an earlier attempt already delivered.
public struct ShareItem: Identifiable, Sendable {
    public let id: String
    public let name: String
    /// The size on disk, for the pre-flight checks. Fitting an image can only make it smaller.
    public let sizeBytes: Int
    public let prepare: @Sendable (ShareFitPolicy) throws -> ShareFile

    public init(
        id: String = UUID().uuidString.lowercased(), name: String, sizeBytes: Int,
        prepare: @escaping @Sendable (ShareFitPolicy) throws -> ShareFile
    ) {
        self.id = id
        self.name = name
        self.sizeBytes = sizeBytes
        self.prepare = prepare
    }
}

/// Where shared files land.
public enum ShareDestination: Equatable, Sendable {
    /// Each file goes to the orders pipeline, which reads it and places it on an entry.
    case orders
    /// One new draft in this account with every file attached.
    case draft(accountId: UUID, accountName: String)
}

/// A shared item that could not be turned into a file to send.
public enum ShareError: Error, Equatable {
    case tooLarge(name: String)
}

/// What an image needs before it is sent. Pure, so the rules are tested without an image library.
public enum ShareImagePlan {
    public struct Plan: Equatable, Sendable {
        /// Re-encode as JPEG, scaled so the long edge is at most this; `nil` keeps the size.
        public let maxLongEdge: Double?
    }

    /// `nil` means the bytes go out as they are.
    ///
    /// Orders takes only PNG and JPEG and the Photos library hands out HEIC, which the server
    /// answers with `415`, so everything else is re-encoded and an image larger than the fit is
    /// scaled down. A mail keeps what the person shared except HEIC, which most recipients cannot
    /// open.
    public static func plan(
        contentType: String, filename: String, longestEdge: Double, policy: ShareFitPolicy
    ) -> Plan? {
        let type = contentType.lowercased()
        guard type.hasPrefix("image/") else { return nil }
        switch policy {
        case .orders:
            let convert = type != "image/png" && type != "image/jpeg"
            let scale = longestEdge > ShareLimits.ordersImageLongEdge
            guard convert || scale else { return nil }
            return Plan(maxLongEdge: scale ? ShareLimits.ordersImageLongEdge : nil)
        case .draft:
            guard OrderUploadFile.needsJPEGConversion(contentType: type, filename: filename) else { return nil }
            return Plan(maxLongEdge: nil)
        }
    }
}
