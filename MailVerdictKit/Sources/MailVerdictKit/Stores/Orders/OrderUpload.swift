import Foundation

/// A file being added to an order, as the detail shows it until it is part of the order.
public struct OrderUpload: Identifiable, Sendable, Equatable {
    public enum Phase: Sendable, Equatable {
        case uploading
        /// Sent; the orders queue is reading it.
        case analysing
        case failed(String)
    }

    public let id: UUID
    public let filename: String
    public var state: Phase

    public init(id: UUID = UUID(), filename: String, state: Phase = .uploading) {
        self.id = id
        self.filename = filename
        self.state = state
    }
}

/// What the server cannot read as it comes from the phone. It stores HEIC, which is what the
/// Photos library hands out, but cannot read it, so images are converted to JPEG before they are sent.
public enum OrderUploadFile {
    public static func needsJPEGConversion(contentType: String?, filename: String) -> Bool {
        let type = contentType?.lowercased() ?? ""
        if type == "image/heic" || type == "image/heif" || type == "image/heic-sequence" { return true }
        let ext = (filename as NSString).pathExtension.lowercased()
        return ext == "heic" || ext == "heif"
    }

    /// `IMG_0001.HEIC` -> `IMG_0001.jpg`.
    public static func jpegFilename(for filename: String) -> String {
        let base = (filename as NSString).deletingPathExtension
        return (base.isEmpty ? "image" : base) + ".jpg"
    }
}
