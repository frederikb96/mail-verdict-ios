import Foundation
import SwiftSoup

public struct ComposeHTMLParseResult: Sendable {
    public var document: ComposeDocument
    /// Images the HTML carried as `data:` URIs, each given a fresh content id the document's
    /// image runs reference — they become inline attachments rather than base64 in the body.
    public var images: [ComposeInlineImage]
}

/// Reads HTML — a paste, a reopened draft, a cancelled send — into the composer's document.
///
/// Anything the editor has no representation for degrades to its text rather than disappearing:
/// a table becomes one line per row with cells tab-separated, an unknown element contributes its
/// children. Remote images are dropped, since a message can only carry an image it attaches.
public enum ComposeHTMLParser {

    public static func parse(
        _ html: String, makeContentId: @escaping () -> String = ComposeContentId.make
    ) -> ComposeHTMLParseResult {
        guard let parsed = try? SwiftSoup.parseBodyFragment(html), let body = parsed.body() else {
            return ComposeHTMLParseResult(document: .empty, images: [])
        }
        let builder = ComposeHTMLBuilder(makeContentId: makeContentId)
        builder.walkChildren(of: body, ComposeHTMLBuilder.Context())
        builder.flush()
        return ComposeHTMLParseResult(
            document: ComposeDocument(blocks: builder.blocks).normalized(), images: builder.images)
    }
}

/// Splits the quote wrapper back out of a saved body — a reopened draft or a cancelled send
/// carries its quote inside `body_html`, and the composer shows it as the separate, uneditable
/// card it was.
public enum ComposeQuoteSplitter {

    /// Matches both shapes a wrapper comes back in: the composer's own marker, and the bare
    /// `div.gmail_quote` the server's sanitizer leaves when it drops unknown data attributes.
    static let wrapperSelector = "div[data-quoted-message=true], div.gmail_quote"

    public static func split(_ html: String) -> (body: String, quote: ComposeQuote?) {
        guard let parsed = try? SwiftSoup.parseBodyFragment(html), let body = parsed.body() else {
            return (html, nil)
        }
        parsed.outputSettings().prettyPrint(pretty: false)
        guard let wrapper = try? body.select(wrapperSelector).first() else { return (html, nil) }

        // The first match in document order — the composer's own wrapper is always outermost, so
        // a forged one nested inside quoted content is never the one read.
        let attribution = (try? wrapper.select(".gmail_attr").first()).map(multilineText) ?? ""
        let quoted = (try? wrapper.select("blockquote").first()).flatMap { try? $0.html() } ?? ""
        try? wrapper.remove()
        return ((try? body.html()) ?? "", ComposeQuote(html: quoted, attribution: attribution))
    }

    /// Text nodes joined, with each `<br>` as a newline — the inverse of how the attribution is
    /// written; an element's plain text would lose every line break.
    private static func multilineText(_ element: Element) -> String {
        element.getChildNodes().map { node -> String in
            if let text = node as? TextNode { return text.getWholeText() }
            if let child = node as? Element, child.tagName().lowercased() == "br" { return "\n" }
            return ""
        }.joined()
    }
}

private final class ComposeHTMLBuilder {

    struct Context {
        var marks: Set<ComposeMark> = []
        var link: String?
        var block: ComposeBlockKind = .paragraph
        var listDepth = 0
        var listKind: ComposeListKind?
        var inPre = false
        var inCell = false
    }

    private(set) var blocks: [ComposeBlock] = []
    private(set) var images: [ComposeInlineImage] = []
    private var kind: ComposeBlockKind = .paragraph
    private var runs: [ComposeRun] = []
    /// HTML ignores one newline directly after `<pre>`'s opening tag.
    private var atPreStart = false
    private let makeContentId: () -> String

    init(makeContentId: @escaping () -> String) {
        self.makeContentId = makeContentId
    }

    private static let skippedTags: Set<String> = [
        "script", "style", "head", "title", "meta", "link", "template", "noscript", "iframe", "object",
        "svg", "button", "select", "textarea",
    ]

    private static let blockTags: Set<String> = [
        "p", "div", "section", "article", "header", "footer", "main", "aside", "nav", "address",
        "figure", "figcaption", "center", "dl", "dt", "dd", "caption", "details", "summary",
    ]

    func walkChildren(of element: Element, _ context: Context) {
        for child in element.getChildNodes() { walk(child, context) }
    }

    private func walk(_ node: Node, _ context: Context) {
        if let text = node as? TextNode {
            appendText(text.getWholeText(), context)
            return
        }
        guard let element = node as? Element else { return }
        let tag = element.tagName().lowercased()
        if Self.skippedTags.contains(tag) { return }

        var inner = context
        applyTagMarks(tag, element, &inner)
        applyStyle(element, &inner)

        switch tag {
        case "br":
            if context.inPre {
                flush(emitEmpty: true)
            } else if context.inCell {
                appendSeparatorSpace(context)
            } else {
                runs.append(ComposeRun(.lineBreak, marks: context.marks, link: context.link))
            }
        case "img":
            appendImage(element, inner)
        case "input":
            // A checkbox's state is read by the list item that owns it.
            break
        case "hr":
            if !context.inCell { flush() }
        case "ul", "ol":
            list(element, ordered: tag == "ol", inner)
        case "li":
            listItem(element, inner)
        case "pre":
            pre(element, inner)
        case "table", "thead", "tbody", "tfoot":
            if !context.inCell { flush() }
            walkChildren(of: element, inner)
            if !context.inCell { flush() }
        case "tr":
            row(element, inner)
        case "blockquote":
            block(element, kind: inner.block.listKind != nil ? inner.block : .quote, inner)
        case "h1", "h2", "h3", "h4", "h5", "h6":
            let level = Int(tag.dropFirst()) ?? 1
            block(element, kind: inner.block == .paragraph ? .heading(level: level) : inner.block, inner)
        default:
            if Self.blockTags.contains(tag) {
                block(element, kind: inner.block, inner)
            } else {
                walkChildren(of: element, inner)
            }
        }
    }

    // MARK: - Structure

    /// A block element closes whatever paragraph was open, and emits an empty paragraph of its own
    /// when it held nothing — `<p></p>` is a blank line someone typed, and has to survive.
    private func block(_ element: Element, kind blockKind: ComposeBlockKind, _ context: Context) {
        if context.inCell {
            appendSeparatorSpace(context)
            walkChildren(of: element, context)
            return
        }
        flush()
        let blockCountBefore = blocks.count
        let outerKind = kind
        kind = blockKind
        var inner = context
        inner.block = blockKind
        walkChildren(of: element, inner)
        flush(emitEmpty: blocks.count == blockCountBefore)
        kind = outerKind
    }

    private func list(_ element: Element, ordered: Bool, _ context: Context) {
        if context.inCell {
            walkChildren(of: element, context)
            return
        }
        flush()
        var inner = context
        inner.listDepth += 1
        if ordered {
            inner.listKind = .ordered
        } else if (try? element.attr("data-type")) == "taskList" {
            inner.listKind = .checklist
        } else {
            inner.listKind = .bullet
        }
        walkChildren(of: element, inner)
        flush()
    }

    private func listItem(_ element: Element, _ context: Context) {
        var listKind = context.listKind ?? .bullet
        var checked = (try? element.attr("data-checked")) == "true"
        // Everywhere but this editor, a rendered checklist is an ordinary `<li>` with a checkbox
        // in front of its text — which is what a browser copies.
        if let box = Self.ownCheckbox(in: element) {
            listKind = .checklist
            checked = box.hasAttr("checked")
        }
        let level = max(context.listDepth - 1, 0)
        block(element, kind: .listItem(listKind, level: level, checked: listKind == .checklist && checked), context)
    }

    /// The item's own checkbox, never one belonging to a nested list inside it.
    private static func ownCheckbox(in element: Element) -> Element? {
        for child in element.children().array() {
            let tag = child.tagName().lowercased()
            if tag == "ul" || tag == "ol" { continue }
            if tag == "input", (try? child.attr("type"))?.lowercased() == "checkbox" { return child }
            if let found = ownCheckbox(in: child) { return found }
        }
        return nil
    }

    private func pre(_ element: Element, _ context: Context) {
        if context.inCell {
            walkChildren(of: element, context)
            return
        }
        flush()
        let outerKind = kind
        kind = .codeBlock
        var inner = context
        inner.inPre = true
        inner.block = .codeBlock
        atPreStart = true
        walkChildren(of: element, inner)
        flush()
        atPreStart = false
        kind = outerKind
    }

    /// One paragraph per table row, cells separated by a tab — the editor has no table, and a
    /// row read left to right is what survives of one in plain text too.
    private func row(_ element: Element, _ context: Context) {
        if context.inCell {
            walkChildren(of: element, context)
            return
        }
        flush()
        let outerKind = kind
        kind = context.block
        var inner = context
        inner.inCell = true
        var firstCell = true
        for child in element.getChildNodes() {
            guard let cell = child as? Element else { continue }
            let tag = cell.tagName().lowercased()
            guard tag == "td" || tag == "th" else { continue }
            if !firstCell { runs.append(.text("\t")) }
            firstCell = false
            walkChildren(of: cell, inner)
        }
        flush()
        kind = outerKind
    }

    // MARK: - Inline content

    private func appendText(_ raw: String, _ context: Context) {
        if context.inPre {
            var value = raw.replacingOccurrences(of: "\r", with: "")
            if atPreStart, value.hasPrefix("\n") { value.removeFirst() }
            if !value.isEmpty { atPreStart = false }
            for (index, line) in value.components(separatedBy: "\n").enumerated() {
                if index > 0 { flush(emitEmpty: true) }
                if !line.isEmpty { runs.append(.text(line)) }
            }
            return
        }
        var value = raw.replacingOccurrences(of: "[ \\t\\n\\r\\f]+", with: " ", options: .regularExpression)
        if value.hasPrefix(" "), atLineStart { value.removeFirst() }
        guard !value.isEmpty else { return }
        runs.append(ComposeRun(.text(value), marks: context.marks, link: context.link))
    }

    /// Where a collapsed leading space would be invisible anyway: at a line's start, or after
    /// whitespace already written.
    private var atLineStart: Bool {
        guard let last = runs.last else { return true }
        switch last.content {
        case .lineBreak: return true
        case .image: return false
        case .text(let value): return value.last == " " || value.last == "\t"
        }
    }

    private func appendSeparatorSpace(_ context: Context) {
        guard !atLineStart else { return }
        runs.append(ComposeRun(.text(" "), marks: context.marks, link: context.link))
    }

    private func appendImage(_ element: Element, _ context: Context) {
        let source = ((try? element.attr("src")) ?? "").trimmingCharacters(in: .whitespaces)
        let width = Self.nonEmpty(try? element.attr("width"))
        let alt = Self.nonEmpty(try? element.attr("alt"))
        let reference: ComposeImageRef
        if source.lowercased().hasPrefix("cid:") {
            reference = ComposeImageRef(contentId: String(source.dropFirst(4)), width: width, alt: alt)
        } else if source.lowercased().hasPrefix("data:"), let decoded = Self.decodeDataURI(source) {
            let contentId = makeContentId()
            let subtype = decoded.mime.split(separator: "/").last.map(String.init) ?? "img"
            let fileExtension = subtype == "jpeg" ? "jpg" : subtype
            images.append(
                ComposeInlineImage(
                    contentId: contentId, filename: "pasted-image-\(images.count + 1).\(fileExtension)",
                    contentType: decoded.mime, data: decoded.data))
            reference = ComposeImageRef(contentId: contentId, width: width, alt: alt)
        } else {
            return
        }
        runs.append(ComposeRun(.image(reference), marks: context.marks, link: context.link))
    }

    static func decodeDataURI(_ uri: String) -> (mime: String, data: Data)? {
        guard let comma = uri.firstIndex(of: ",") else { return nil }
        let header = uri[uri.index(uri.startIndex, offsetBy: 5)..<comma]
        let payload = String(uri[uri.index(after: comma)...])
        let parameters = header.split(separator: ";").map { $0.lowercased() }
        let mime = parameters.first.flatMap { $0.contains("/") ? $0 : nil } ?? "application/octet-stream"
        guard mime.hasPrefix("image/") else { return nil }
        let data: Data?
        if parameters.contains("base64") {
            data = Data(base64Encoded: payload, options: .ignoreUnknownCharacters)
        } else {
            data = payload.removingPercentEncoding.map { Data($0.utf8) }
        }
        guard let data, !data.isEmpty else { return nil }
        return (mime, data)
    }

    // MARK: - Marks

    private func applyTagMarks(_ tag: String, _ element: Element, _ context: inout Context) {
        switch tag {
        case "b", "strong": context.marks.insert(.bold)
        case "i", "em", "cite", "dfn", "var": context.marks.insert(.italic)
        case "u", "ins": context.marks.insert(.underline)
        case "s", "strike", "del": context.marks.insert(.strikethrough)
        case "code", "kbd", "samp", "tt": if !context.inPre { context.marks.insert(.code) }
        case "a": context.link = Self.safeLink(try? element.attr("href"))
        default: break
        }
    }

    /// Inline styles after tag marks, because some sources wrap everything in
    /// `<b style="font-weight:normal">` and mean the style.
    private func applyStyle(_ element: Element, _ context: inout Context) {
        guard let style = try? element.attr("style"), !style.isEmpty else { return }
        for declaration in style.lowercased().split(separator: ";") {
            let pair = declaration.split(separator: ":", maxSplits: 1).map {
                $0.trimmingCharacters(in: .whitespaces)
            }
            guard pair.count == 2 else { continue }
            let value = pair[1]
            switch pair[0] {
            case "font-weight":
                if value == "bold" || value == "bolder" || (Int(value) ?? 0) >= 600 {
                    context.marks.insert(.bold)
                } else if value == "normal" || value == "lighter" || (Int(value).map { $0 < 600 } ?? false) {
                    context.marks.remove(.bold)
                }
            case "font-style":
                if value.hasPrefix("italic") || value.hasPrefix("oblique") {
                    context.marks.insert(.italic)
                } else if value == "normal" {
                    context.marks.remove(.italic)
                }
            case "text-decoration", "text-decoration-line":
                if value.contains("underline") { context.marks.insert(.underline) }
                if value.contains("line-through") { context.marks.insert(.strikethrough) }
            default:
                break
            }
        }
    }

    /// Only targets a recipient can follow; anything else keeps its text and loses the link.
    static func safeLink(_ href: String?) -> String? {
        guard let href = href?.trimmingCharacters(in: .whitespacesAndNewlines), !href.isEmpty else { return nil }
        let lowered = href.lowercased()
        guard lowered.hasPrefix("http://") || lowered.hasPrefix("https://") || lowered.hasPrefix("mailto:") else {
            return nil
        }
        return href
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespaces), !value.isEmpty else { return nil }
        return value
    }

    // MARK: - Emitting

    /// Closes the open paragraph. One trailing line break is dropped — it is the filler an empty
    /// or break-ended paragraph carries, not content — and trailing collapsed whitespace with it.
    func flush(emitEmpty: Bool = false) {
        if kind != .codeBlock {
            if case .lineBreak = runs.last?.content { runs.removeLast() }
            trimTrailingWhitespace()
        }
        guard !runs.isEmpty || emitEmpty else {
            runs = []
            return
        }
        var blockKind = kind
        if case .listItem(_, let level, _) = kind, let glyph = Self.checklistGlyph(runs) {
            blockKind = .listItem(.checklist, level: level, checked: glyph.checked)
            runs = glyph.remaining
        }
        blocks.append(ComposeBlock(blockKind, runs))
        runs = []
    }

    private func trimTrailingWhitespace() {
        while let last = runs.last, case .text(let value) = last.content {
            var trimmed = value
            while let character = trimmed.last, character == " " || character == "\t" { trimmed.removeLast() }
            if trimmed.isEmpty {
                runs.removeLast()
                continue
            }
            runs[runs.count - 1].content = .text(trimmed)
            break
        }
    }

    /// The server's sanitizer sends a checklist as list items starting with a ballot box, so a
    /// draft saved with one comes back in that form; reading the glyph restores the checklist.
    private static func checklistGlyph(_ runs: [ComposeRun]) -> (checked: Bool, remaining: [ComposeRun])? {
        guard let first = runs.first, case .text(let value) = first.content, let glyph = value.first,
            glyph == "\u{2610}" || glyph == "\u{2611}"
        else { return nil }
        var rest = String(value.dropFirst())
        if let separator = rest.first, separator == "\u{00A0}" || separator == " " { rest.removeFirst() }
        var remaining = runs
        if rest.isEmpty {
            remaining.removeFirst()
        } else {
            remaining[0].content = .text(rest)
        }
        return (glyph == "\u{2611}", remaining)
    }
}
