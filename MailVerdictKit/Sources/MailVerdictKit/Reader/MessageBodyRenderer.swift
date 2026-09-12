import Foundation

/// One message body, ready for its shadow root.
public struct MessageBodyRendering: Sendable, Equatable {
    public let canvas: MVCanvas
    /// Whether the body was HTML — the canvas toggle is only offered then, as on the web: a plain
    /// text body carries no colours of its own and follows the app theme.
    public let isHTML: Bool
    /// The shadow root's whole content: the canvas stylesheet, then the message.
    public let shadowContent: String
}

/// The body pipeline — port of `EmailRenderer`'s render effect in `email-renderer.tsx`: sanitize,
/// collapse the reply quote, point attachment URLs at the reader's own scheme, pick the canvas,
/// align the message's colour-scheme queries to it. Plain text is escaped and linkified instead.
public enum MessageBodyRenderer {

    public static let attachmentScheme = "mv-attachment"

    /// The backend rewrites a `cid:` image to this same-origin path (`_rewrite_cid_references`
    /// in `api/mails.py`). A web view cannot attach a credential to a subresource request, so
    /// the reader serves these through a scheme handler instead.
    private static let attachmentPathPattern =
        #"^/api/messages/([0-9a-fA-F-]{36})/attachments/([0-9a-fA-F-]{36})$"#

    public static func render(
        bodyHTML: String?, bodyText: String?, theme: MVCanvas, manualCanvas: MVCanvas?
    ) -> MessageBodyRendering {
        if let bodyHTML, !bodyHTML.isEmpty {
            let canvas = manualCanvas ?? CanvasPicker.pickCanvas(html: bodyHTML, theme: theme)
            let markup = MessageMarkupWriter.write(
                bodyHTML,
                options: MessageMarkupOptions(
                    collapsesReplyQuote: true, alignsColorSchemeTo: canvas, rewritesAttachmentURLs: true))
            return MessageBodyRendering(canvas: canvas, isHTML: true, shadowContent: styleTag(canvas) + markup)
        }
        let content: String
        if let bodyText, !bodyText.isEmpty {
            content = PlainTextLinkifier.render(bodyText)
        } else {
            content = #"<p style="color: #71717a; font-style: italic;">No content available</p>"#
        }
        return MessageBodyRendering(canvas: theme, isHTML: false, shadowContent: styleTag(theme) + content)
    }

    public static func attachmentURL(messageId: UUID, attachmentId: UUID) -> String {
        "\(attachmentScheme)://\(messageId.uuidString.lowercased())/\(attachmentId.uuidString.lowercased())"
    }

    static func rewrittenAttachmentURL(_ value: String) -> String? {
        let ns = value as NSString
        guard let regex = try? NSRegularExpression(pattern: attachmentPathPattern),
            let match = regex.firstMatch(in: value, range: NSRange(location: 0, length: ns.length)),
            let messageId = UUID(uuidString: ns.substring(with: match.range(at: 1))),
            let attachmentId = UUID(uuidString: ns.substring(with: match.range(at: 2)))
        else { return nil }
        return attachmentURL(messageId: messageId, attachmentId: attachmentId)
    }

    private static func styleTag(_ canvas: MVCanvas) -> String {
        "<style>\(EmailStyles.css(for: canvas))</style>"
    }
}
