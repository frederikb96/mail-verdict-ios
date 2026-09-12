import Foundation
import SwiftSoup

/// The client-side half of message sanitization: a port of the DOMPurify pass in the web's
/// `email-renderer.tsx` — its `ALLOWED_TAGS`/`ALLOWED_ATTR` lists plus DOMPurify's own URI and
/// content rules, which those lists lean on without restating.
///
/// The backend's nh3 pass has already run, so this is defence in depth. It is also what keeps a
/// body inside the declarative shadow root the reader places it in: `MessageMarkupWriter` emits
/// only what these lists allow and re-escapes all text, so no template tag survives in any form.
public enum MessageHTMLSanitizer {

    static let allowedTags: Set<String> = [
        "a", "abbr", "address", "article", "b", "blockquote", "br", "caption", "center", "cite",
        "code", "col", "colgroup", "dd", "del", "details", "dfn", "div", "dl", "dt", "em",
        "figcaption", "figure", "font", "footer", "h1", "h2", "h3", "h4", "h5", "h6", "header",
        "hr", "i", "img", "ins", "kbd", "li", "main", "mark", "nav", "ol", "p", "pre", "q", "s",
        "section", "small", "span", "strong", "style", "sub", "summary", "sup", "table", "tbody",
        "td", "tfoot", "th", "thead", "tr", "u", "ul", "wbr",
    ]

    static let allowedAttributes: Set<String> = [
        "align", "alt", "background", "border", "cellpadding", "cellspacing", "class", "color",
        "colspan", "dir", "face", "height", "href", "hspace", "id", "lang", "media", "role",
        "rowspan", "size", "src", "style", "summary", "target", "title", "type", "valign",
        "vspace", "width",
    ]

    /// DOMPurify's default `FORBID_CONTENTS`: a disallowed element whose children go with it
    /// instead of being hoisted into the surrounding markup. Every other disallowed element is
    /// unwrapped, keeping its text.
    static let contentForbiddenTags: Set<String> = [
        "annotation-xml", "audio", "colgroup", "desc", "foreignobject", "head", "iframe", "math",
        "mi", "mn", "mo", "ms", "mtext", "noembed", "noframes", "noscript", "plaintext", "script",
        "style", "svg", "template", "thead", "title", "video", "xmp",
    ]

    /// DOMPurify's `URI_SAFE_ATTRIBUTES` — values it never runs through the URI check.
    static let uriSafeAttributes: Set<String> = [
        "alt", "class", "for", "id", "label", "name", "pattern", "placeholder", "role", "summary",
        "title", "value", "style", "xmlns",
    ]

    /// DOMPurify's `DATA_URI_TAGS` — the only elements a `data:` URI may appear on.
    static let dataURITags: Set<String> = ["audio", "video", "img", "source", "image", "track"]

    /// DOMPurify's `ALLOWED_URI_REGEXP`: a known-safe scheme, or no scheme at all (a relative
    /// URL, a fragment, or a plain word such as an `align` value).
    private static let allowedURIPattern =
        #"^(?:(?:(?:f|ht)tps?|mailto|tel|callto|sms|cid|xmpp|matrix):|[^a-z]|[a-z+.\-]+(?:[^a-z+.\-:]|$))"#

    /// DOMPurify's `ATTR_WHITESPACE`, stripped before the URI check so `java\tscript:` cannot
    /// pass as a schemeless word.
    private static let attributeWhitespacePattern =
        #"[\x{0}-\x{20}\x{A0}\x{1680}\x{180E}\x{2000}-\x{2029}\x{205F}\x{3000}]"#

    /// DOMPurify's `SAFE_FOR_XML` attribute check: a value that could end a comment or a raw
    /// text element once serialized.
    private static let markupBreakoutPattern = #"((--!?|])>)|</(style|title)"#

    /// A body with nothing done to it but sanitization.
    public static func sanitize(_ html: String) -> String {
        MessageMarkupWriter.write(html, options: MessageMarkupOptions())
    }

    static func isAllowed(attribute name: String, value: String, tag: String) -> Bool {
        guard allowedAttributes.contains(name) else { return false }
        if value.range(of: markupBreakoutPattern, options: [.regularExpression, .caseInsensitive]) != nil {
            return false
        }
        if uriSafeAttributes.contains(name) { return true }

        let compact = value.replacingOccurrences(
            of: attributeWhitespacePattern, with: "", options: .regularExpression)
        if compact.isEmpty { return true }
        if compact.range(of: allowedURIPattern, options: [.regularExpression, .caseInsensitive]) != nil {
            return true
        }
        return (name == "src" || name == "href") && dataURITags.contains(tag) && value.hasPrefix("data:")
    }
}

/// What `MessageMarkupWriter` does beyond sanitizing.
struct MessageMarkupOptions {
    /// Wrap the first reply quote in a collapsed `<details>` (`QuoteCollapser`).
    var collapsesReplyQuote = false
    /// Rewrite the message's own colour-scheme queries for this canvas (`ColorSchemeQueryAligner`).
    var alignsColorSchemeTo: MVCanvas?
    /// Point the backend's inline-attachment paths at the reader's own scheme.
    var rewritesAttachmentURLs = false
}

/// The reader's only serializer for message markup: SwiftSoup parses a body, and this writes it
/// back out. SwiftSoup's own serializer can hand back a node's original source text after the
/// node was changed, which is not something a sanitizer can rest on — so nothing reaches the page
/// unless this writer emitted it: allowlisted elements and attributes only, all text re-escaped,
/// and `<style>` contents re-emitted with any style end tag neutralized.
enum MessageMarkupWriter {

    static let voidTags: Set<String> = ["br", "hr", "img", "wbr", "col"]
    static let urlAttributes: Set<String> = ["src", "href", "background"]

    static func write(_ html: String, options: MessageMarkupOptions) -> String {
        guard let document = try? SwiftSoup.parseBodyFragment(html), let body = document.body() else {
            return ""
        }
        var writer = Writer(options: options, root: body)
        for node in body.getChildNodes() {
            writer.write(node)
        }
        return writer.output
    }

    static func escapeText(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }

    static func escapeAttribute(_ value: String) -> String {
        escapeText(value).replacingOccurrences(of: "\"", with: "&quot;")
    }

    private struct Writer {
        let options: MessageMarkupOptions
        let root: Element
        var output = ""
        var wroteQuoteWrap = false

        mutating func write(_ node: Node) {
            if let text = node as? TextNode {
                output += MessageMarkupWriter.escapeText(text.getWholeText())
                return
            }
            // Comments, doctypes and anything else that is not an element or text are dropped.
            guard let element = node as? Element else { return }
            let tag = element.tagNameNormal()
            guard MessageHTMLSanitizer.allowedTags.contains(tag) else {
                if !MessageHTMLSanitizer.contentForbiddenTags.contains(tag) {
                    for child in element.getChildNodes() { write(child) }
                }
                return
            }

            // Only the first reply quote in document order is wrapped; set before its children are
            // written, so a quote nested inside it is never wrapped a second time.
            let wrapsQuote =
                tag == "blockquote" && options.collapsesReplyQuote && !wroteQuoteWrap
                && QuoteCollapser.isReplyQuote(element, root: root)
            if wrapsQuote {
                wroteQuoteWrap = true
                output += QuoteCollapser.openingMarkup
            }

            output += "<\(tag)\(attributes(of: element, tag: tag))>"
            if tag == "style" {
                output += styleText(element)
            } else if !MessageMarkupWriter.voidTags.contains(tag) {
                for child in element.getChildNodes() { write(child) }
            }
            if !MessageMarkupWriter.voidTags.contains(tag) {
                output += "</\(tag)>"
            }
            if wrapsQuote {
                output += "</details>"
            }
        }

        private func attributes(of element: Element, tag: String) -> String {
            guard let attributes = element.getAttributes() else { return "" }
            var written = ""
            var seen: Set<String> = []
            for attribute in attributes {
                let name = attribute.getKey().lowercased()
                var value = attribute.getValue()
                guard seen.insert(name).inserted,
                    MessageHTMLSanitizer.isAllowed(attribute: name, value: value, tag: tag)
                else { continue }
                if options.rewritesAttachmentURLs, MessageMarkupWriter.urlAttributes.contains(name),
                    let rewritten = MessageBodyRenderer.rewrittenAttachmentURL(value)
                {
                    value = rewritten
                }
                if tag == "style", name == "media", let canvas = options.alignsColorSchemeTo {
                    value = ColorSchemeQueryAligner.align(value, canvas: canvas)
                }
                written += " \(name)=\"\(MessageMarkupWriter.escapeAttribute(value))\""
            }
            return written
        }

        /// A stylesheet is raw text: escaping it would break the CSS, so instead the one sequence
        /// that could end it early is defused.
        private func styleText(_ element: Element) -> String {
            var css = ""
            for child in element.getChildNodes() {
                if let data = child as? DataNode {
                    css += data.getWholeData()
                } else if let text = child as? TextNode {
                    css += text.getWholeText()
                }
            }
            if let canvas = options.alignsColorSchemeTo {
                css = ColorSchemeQueryAligner.align(css, canvas: canvas)
            }
            return css.replacingOccurrences(of: "</style", with: "<\\/style", options: .caseInsensitive)
        }
    }
}
