import Foundation

/// A reply or forward's quoted original. It sits under the authored body exactly as the server
/// returned it and is never parsed into the document, so nothing the editor cannot represent (a
/// table, a styled newsletter) is flattened on the way out.
public struct ComposeQuote: Hashable, Codable, Sendable {
    public var html: String
    /// "On <date>, <name> wrote:" for a reply; the multi-line forwarded-message header for a
    /// forward.
    public var attribution: String

    public init(html: String, attribution: String) {
        self.html = html
        self.attribution = attribution
    }
}

/// The composer body as outgoing HTML — the same shapes the web editor emits, so the server's
/// outbound sanitizer treats a message from either client identically and a draft saved by one
/// reopens in the other.
public enum ComposeHTMLSerializer {

    /// Gmail's quote-bar declaration, the one every client recognises.
    static let quoteBarStyle = "margin:0 0 0 .8ex;border-left:1px #ccc solid;padding-left:1ex"

    /// `body_html` for a submission: the authored document followed by the quote wrapper, or
    /// `nil` when there is neither text nor a quote to send.
    public static func body(_ document: ComposeDocument, quote: ComposeQuote?) -> String? {
        guard !document.isEmpty || quote != nil else { return nil }
        return html(document) + (quote.map(quoteHTML) ?? "")
    }

    public static func html(_ document: ComposeDocument) -> String {
        let blocks = document.normalized().blocks
        var out = ""
        var index = 0
        while index < blocks.count {
            let block = blocks[index]
            switch block.kind {
            case .paragraph:
                out += "<p>\(paragraphContent(block.runs))</p>"
                index += 1
            case .heading(let level):
                out += "<h\(level)>\(paragraphContent(block.runs))</h\(level)>"
                index += 1
            case .quote:
                out += "<blockquote>"
                while index < blocks.count, blocks[index].kind == .quote {
                    out += "<p>\(paragraphContent(blocks[index].runs))</p>"
                    index += 1
                }
                out += "</blockquote>"
            case .codeBlock:
                var lines: [String] = []
                while index < blocks.count, blocks[index].kind == .codeBlock {
                    lines.append(escapeText(blocks[index].plainText))
                    index += 1
                }
                out += "<pre><code>\(lines.joined(separator: "\n"))</code></pre>"
            case .listItem:
                var items: [ComposeBlock] = []
                while index < blocks.count, blocks[index].kind.listKind != nil {
                    items.append(blocks[index])
                    index += 1
                }
                var cursor = 0
                out += lists(items, &cursor, level: 0)
            }
        }
        return out
    }

    /// The quote wrapper the web editor's quoted-message node writes, attribute for attribute —
    /// `data-quoted-message` is what either client matches to rebuild the quote when a draft is
    /// reopened, and `gmail_quote`/`gmail_attr` are what survives the server's sanitizer.
    public static func quoteHTML(_ quote: ComposeQuote) -> String {
        let attribution = quote.attribution.components(separatedBy: "\n").map(escapeText)
            .joined(separator: "<br>")
        return "<div data-quoted-message=\"true\" class=\"gmail_quote\">"
            + "<div class=\"gmail_attr\">\(attribution)</div>"
            + "<blockquote type=\"cite\" class=\"gmail_quote\" style=\"\(quoteBarStyle)\">\(quote.html)</blockquote>"
            + "</div>"
    }

    // MARK: - Lists

    /// Consecutive list items become nested `<ul>`/`<ol>` elements. A change of kind at the same
    /// level closes one list and opens the next, which is the only way HTML can say it.
    private static func lists(_ items: [ComposeBlock], _ index: inout Int, level: Int) -> String {
        var out = ""
        while index < items.count, let itemLevel = items[index].kind.listLevel, itemLevel >= level,
            let kind = items[index].kind.listKind
        {
            out += kind == .ordered ? "<ol>" : (kind == .checklist ? "<ul data-type=\"taskList\">" : "<ul>")
            // `repeat` so the first item is always consumed, whatever its level — a loop that
            // could leave it unconsumed would never terminate.
            repeat {
                let item = items[index]
                index += 1
                out += listItem(item)
                if index < items.count, let next = items[index].kind.listLevel, next > level {
                    out += lists(items, &index, level: level + 1)
                }
                out += "</li>"
            } while index < items.count && items[index].kind.listLevel == level && items[index].kind.listKind == kind
            out += kind == .ordered ? "</ol>" : "</ul>"
        }
        return out
    }

    private static func listItem(_ item: ComposeBlock) -> String {
        let content = paragraphContent(item.runs)
        guard case .listItem(.checklist, _, let checked) = item.kind else {
            return "<li><p>\(content)</p>"
        }
        let box = checked ? "<input type=\"checkbox\" checked=\"checked\">" : "<input type=\"checkbox\">"
        return "<li data-checked=\"\(checked)\" data-type=\"taskItem\"><label>\(box)<span></span></label>"
            + "<div><p>\(content)</p></div>"
    }

    // MARK: - Inline

    /// A paragraph with no content, or one ending in a line break, needs a trailing `<br>` to
    /// occupy the line it stands for — HTML renders an empty `<p>` and a final `<br>` as nothing.
    private static func paragraphContent(_ runs: [ComposeRun]) -> String {
        var out = inline(runs)
        if runs.isEmpty { return "<br>" }
        if case .lineBreak = runs.last?.content { out += "<br>" }
        return out
    }

    private static let markTags: [(ComposeMark, String)] = [
        (.bold, "strong"), (.italic, "em"), (.underline, "u"), (.strikethrough, "s"), (.code, "code"),
    ]

    static func inline(_ runs: [ComposeRun]) -> String {
        var out = ""
        var index = 0
        while index < runs.count {
            let link = runs[index].link
            var group = ""
            while index < runs.count, runs[index].link == link {
                group += markup(runs[index])
                index += 1
            }
            if let link {
                out += "<a href=\"\(escapeAttribute(link))\">\(group)</a>"
            } else {
                out += group
            }
        }
        return out
    }

    private static func markup(_ run: ComposeRun) -> String {
        let inner: String
        switch run.content {
        case .text(let value):
            inner = escapeText(value)
        case .lineBreak:
            inner = "<br>"
        case .image(let ref):
            var tag = "<img src=\"cid:\(escapeAttribute(ref.contentId))\""
            if let alt = ref.alt { tag += " alt=\"\(escapeAttribute(alt))\"" }
            if let width = ref.width { tag += " width=\"\(escapeAttribute(width))\"" }
            inner = tag + ">"
        }
        let tags = markTags.filter { run.marks.contains($0.0) }.map(\.1)
        return tags.map { "<\($0)>" }.joined() + inner + tags.reversed().map { "</\($0)>" }.joined()
    }

    static func escapeText(_ value: String) -> String {
        value.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }

    static func escapeAttribute(_ value: String) -> String {
        escapeText(value).replacingOccurrences(of: "\"", with: "&quot;")
    }
}
