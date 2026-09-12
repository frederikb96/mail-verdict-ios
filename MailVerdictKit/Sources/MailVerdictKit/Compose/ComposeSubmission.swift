import Foundation

/// Everything one Send or Save Draft carries, gathered from the composer.
public struct ComposeSubmissionInput: Sendable {
    public var accountId: UUID
    public var kind: OutboxCreateRequest.Kind
    public var to: [String]
    public var cc: [String]
    public var bcc: [String]
    public var subject: String
    public var document: ComposeDocument
    public var quote: ComposeQuote?
    public var quotedText: String
    public var inReplyTo: String?
    public var references: [String]?
    public var identityId: UUID?
    public var replacesMessageId: UUID?
    public var attachments: [ComposeAttachment]
    public var inlineImages: [String: ComposeInlineImage]
    public var idempotencyKey: UUID

    public init(
        accountId: UUID, kind: OutboxCreateRequest.Kind, to: [String], cc: [String], bcc: [String],
        subject: String, document: ComposeDocument, quote: ComposeQuote?, quotedText: String,
        inReplyTo: String?, references: [String]?, identityId: UUID?, replacesMessageId: UUID?,
        attachments: [ComposeAttachment], inlineImages: [String: ComposeInlineImage], idempotencyKey: UUID
    ) {
        self.accountId = accountId
        self.kind = kind
        self.to = to
        self.cc = cc
        self.bcc = bcc
        self.subject = subject
        self.document = document
        self.quote = quote
        self.quotedText = quotedText
        self.inReplyTo = inReplyTo
        self.references = references
        self.identityId = identityId
        self.replacesMessageId = replacesMessageId
        self.attachments = attachments
        self.inlineImages = inlineImages
        self.idempotencyKey = idempotencyKey
    }
}

public enum ComposeSubmission {

    /// The `POST /api/outbox` body and its files. Picked attachments come first, then every
    /// inline image the body still references, and `inline_attachment_content_ids` lines up with
    /// that list position for position: `nil` for a picked file, the content id for an inline
    /// image. An image deleted from the body, or one whose bytes are gone, is neither uploaded nor
    /// referenced.
    public static func build(_ input: ComposeSubmissionInput) -> (
        request: OutboxCreateRequest, uploads: [MVOutboxAttachmentUpload]
    ) {
        let document = withoutMissingImages(input.document, available: input.inlineImages)
        let empty = document.isEmpty
        let inline = empty ? [] : document.referencedContentIds.compactMap { input.inlineImages[$0] }

        let uploads =
            input.attachments.map {
                MVOutboxAttachmentUpload(filename: $0.filename, contentType: $0.contentType, data: $0.data)
            }
            + inline.map { MVOutboxAttachmentUpload(filename: $0.filename, contentType: $0.contentType, data: $0.data) }
        let contentIds: [String?]? =
            uploads.isEmpty ? nil : input.attachments.map { _ in nil } + inline.map { Optional($0.contentId) }

        let request = OutboxCreateRequest(
            accountId: input.accountId, kind: input.kind, to: input.to, cc: input.cc, bcc: input.bcc,
            subject: input.subject,
            bodyText: (empty ? "" : ComposeTextSerializer.text(document)) + input.quotedText,
            bodyHtml: ComposeHTMLSerializer.body(document, quote: input.quote),
            inReplyTo: input.inReplyTo, references: input.references, identityId: input.identityId,
            replacesMessageId: input.replacesMessageId, inlineAttachmentContentIds: contentIds,
            idempotencyKey: input.idempotencyKey)
        return (request, uploads)
    }

    private static func withoutMissingImages(
        _ document: ComposeDocument, available: [String: ComposeInlineImage]
    ) -> ComposeDocument {
        var result = document
        for index in result.blocks.indices {
            result.blocks[index].runs.removeAll { run in
                if case .image(let reference) = run.content { return available[reference.contentId] == nil }
                return false
            }
        }
        return result.normalized()
    }
}
