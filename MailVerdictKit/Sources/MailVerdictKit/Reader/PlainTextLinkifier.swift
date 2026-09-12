import Foundation

/// Plain-text bodies — port of `escapeHtml` and `linkifyText` in `email-renderer.tsx`.
public enum PlainTextLinkifier {

    /// Escapes every character that can change the meaning of markup. Quotes matter as much as
    /// angle brackets: a linkified URL lands inside an `href` attribute, and an unescaped quote
    /// would close it.
    public static func escapeHTML(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&#39;")
    }

    /// Stops at a quote or angle-bracket entity as well as whitespace, so a URL cannot swallow the
    /// boundary of the attribute it is about to be placed in.
    private static let urlRegex = try! NSRegularExpression(
        pattern: #"(https?://(?:(?!&quot;|&#39;|&lt;|&gt;)[^\s<>"'])+)"#)

    /// Links URLs in text that `escapeHTML` has already escaped.
    public static func linkify(_ escaped: String) -> String {
        urlRegex.stringByReplacingMatches(
            in: escaped, range: NSRange(location: 0, length: (escaped as NSString).length),
            withTemplate: #"<a href="$1" target="_blank" rel="noopener noreferrer">$1</a>"#)
    }

    /// A plain-text body as the markup the reader renders: escaped, linkified, whitespace kept.
    public static func render(_ text: String) -> String {
        #"<pre style="white-space: pre-wrap; font-family: inherit; margin: 0;">"#
            + linkify(escapeHTML(text)) + "</pre>"
    }
}
