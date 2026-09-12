import Foundation

/// What a composer's crash-recovery snapshot holds: every authored field, including the files —
/// iOS ends a backgrounded app without warning, so an attachment lost with it would be gone for
/// good.
public struct ComposeRecoveryContent: Equatable, Sendable {
    public var to: [String]
    public var cc: [String]
    public var bcc: [String]
    public var subject: String
    public var document: ComposeDocument
    public var quote: ComposeQuote?
    public var attachments: [ComposeAttachment]
    public var inlineImages: [ComposeInlineImage]

    public init(
        to: [String], cc: [String], bcc: [String], subject: String, document: ComposeDocument,
        quote: ComposeQuote?, attachments: [ComposeAttachment], inlineImages: [ComposeInlineImage]
    ) {
        self.to = to
        self.cc = cc
        self.bcc = bcc
        self.subject = subject
        self.document = document
        self.quote = quote
        self.attachments = attachments
        self.inlineImages = inlineImages
    }
}

/// Snapshots on disk, one folder per composer key: a JSON manifest plus one file per attachment
/// and inline image. A file is written once and kept until it drops out of the snapshot, so the
/// once-a-second rewrite while typing costs the manifest, not the attachments.
public final class ComposeRecoveryStore: Sendable {

    public let directory: URL
    private static let manifestName = "snapshot.json"

    public init(directory: URL) {
        self.directory = directory
    }

    /// Which composer this is, for recovery only: a draft being edited, a reply in progress, or a
    /// fresh message. Every fresh message shares one slot; only one composer is open at a time.
    public static func key(replacesMessageId: UUID?, inReplyTo: String?) -> String {
        if let replacesMessageId { return "draft:\(replacesMessageId.uuidString.lowercased())" }
        if let inReplyTo, !inReplyTo.isEmpty { return "reply:\(inReplyTo)" }
        return "new"
    }

    public func hasSnapshot(key: String) -> Bool {
        FileManager.default.fileExists(atPath: folder(for: key).appendingPathComponent(Self.manifestName).path)
    }

    public func write(_ content: ComposeRecoveryContent, key: String) throws {
        let fileManager = FileManager.default
        let folder = folder(for: key)
        try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)

        var wanted: Set<String> = [Self.manifestName]
        func store(_ data: Data, as name: String) throws {
            wanted.insert(name)
            let url = folder.appendingPathComponent(name)
            if !fileManager.fileExists(atPath: url.path) { try data.write(to: url, options: .atomic) }
        }

        var attachmentEntries: [Manifest.File] = []
        for attachment in content.attachments {
            let name = "attachment-\(attachment.id.uuidString)"
            try store(attachment.data, as: name)
            attachmentEntries.append(
                Manifest.File(
                    id: attachment.id.uuidString, filename: attachment.filename, contentType: attachment.contentType,
                    file: name))
        }
        var imageEntries: [Manifest.File] = []
        for image in content.inlineImages {
            let name = "inline-" + Self.safeName(image.contentId)
            try store(image.data, as: name)
            imageEntries.append(
                Manifest.File(id: image.contentId, filename: image.filename, contentType: image.contentType, file: name)
            )
        }

        // The manifest after its files, so a snapshot read at any moment names only files that
        // exist.
        let manifest = Manifest(
            to: content.to, cc: content.cc, bcc: content.bcc, subject: content.subject, document: content.document,
            quote: content.quote, attachments: attachmentEntries, inlineImages: imageEntries)
        try JSONEncoder().encode(manifest).write(to: folder.appendingPathComponent(Self.manifestName), options: .atomic)

        for existing in (try? fileManager.contentsOfDirectory(atPath: folder.path)) ?? []
        where !wanted.contains(existing) {
            try? fileManager.removeItem(at: folder.appendingPathComponent(existing))
        }
    }

    /// `nil` for no snapshot and for an unreadable one alike — either way there is nothing to
    /// offer back. A file that has gone missing is left out rather than failing the whole read.
    public func read(key: String) -> ComposeRecoveryContent? {
        let folder = folder(for: key)
        guard let data = try? Data(contentsOf: folder.appendingPathComponent(Self.manifestName)),
            let manifest = try? JSONDecoder().decode(Manifest.self, from: data)
        else { return nil }
        let attachments = manifest.attachments.compactMap { entry -> ComposeAttachment? in
            guard let bytes = try? Data(contentsOf: folder.appendingPathComponent(entry.file)) else { return nil }
            return ComposeAttachment(
                id: UUID(uuidString: entry.id) ?? UUID(), filename: entry.filename, contentType: entry.contentType,
                data: bytes)
        }
        let images = manifest.inlineImages.compactMap { entry -> ComposeInlineImage? in
            guard let bytes = try? Data(contentsOf: folder.appendingPathComponent(entry.file)) else { return nil }
            return ComposeInlineImage(
                contentId: entry.id, filename: entry.filename, contentType: entry.contentType, data: bytes)
        }
        return ComposeRecoveryContent(
            to: manifest.to, cc: manifest.cc, bcc: manifest.bcc, subject: manifest.subject, document: manifest.document,
            quote: manifest.quote, attachments: attachments, inlineImages: images)
    }

    public func clear(key: String) {
        try? FileManager.default.removeItem(at: folder(for: key))
    }

    private func folder(for key: String) -> URL {
        directory.appendingPathComponent(Self.safeName(key), isDirectory: true)
    }

    /// A reply key holds a Message-ID (`<…@…>`), which is no file name.
    private static func safeName(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? "composer"
    }

    private struct Manifest: Codable {
        struct File: Codable {
            let id: String
            let filename: String
            let contentType: String?
            let file: String
        }
        let to: [String]
        let cc: [String]
        let bcc: [String]
        let subject: String
        let document: ComposeDocument
        let quote: ComposeQuote?
        let attachments: [File]
        let inlineImages: [File]
    }
}
