import Foundation

/// The composer body as `body_text`: the markdown-flavoured plain text the web editor exports, so
/// a plain-text reader sees list markers, emphasis and link targets rather than bare words. It is
/// an output format only — nothing the person types is ever read as markdown.
///
/// One line per paragraph, not the blank-line-separated paragraphs of strict markdown: Return on
/// an iPhone keyboard starts a new line, and a person who wants a blank line types one.
public enum ComposeTextSerializer {

    public static func text(_ document: ComposeDocument) -> String {
        let blocks = document.normalized().blocks
        var lines: [String] = []
        // Per nesting level: the kind of list open there and the last number it used.
        var openLists: [(kind: ComposeListKind, counter: Int)] = []
        var index = 0
        while index < blocks.count {
            let block = blocks[index]
            guard case .listItem(let kind, let level, let checked) = block.kind else {
                openLists.removeAll()
                switch block.kind {
                case .codeBlock:
                    lines.append("```")
                    while index < blocks.count, blocks[index].kind == .codeBlock {
                        lines.append(blocks[index].plainText)
                        index += 1
                    }
                    lines.append("```")
                    continue
                case .quote:
                    let content = inline(block.runs)
                    lines.append(content.isEmpty ? ">" : "> \(content)")
                case .heading(let level):
                    lines.append(String(repeating: "#", count: level) + " " + inline(block.runs))
                default:
                    lines.append(inline(block.runs))
                }
                index += 1
                continue
            }

            if openLists.count > level + 1 { openLists.removeLast(openLists.count - level - 1) }
            while openLists.count < level { openLists.append((kind, 0)) }
            if openLists.count == level + 1, openLists[level].kind == kind {
                openLists[level].counter += 1
            } else if openLists.count == level + 1 {
                openLists[level] = (kind, 1)
            } else {
                openLists.append((kind, 1))
            }

            let marker: String
            switch kind {
            case .bullet: marker = "- "
            case .ordered: marker = "\(openLists[level].counter). "
            case .checklist: marker = checked ? "- [x] " : "- [ ] "
            }
            lines.append(String(repeating: "  ", count: level) + marker + inline(block.runs))
            index += 1
        }
        return lines.joined(separator: "\n")
    }

    private static let markOrder: [ComposeMark] = [.bold, .italic, .strikethrough, .code, .underline]

    private static func delimiter(_ mark: ComposeMark) -> String {
        switch mark {
        case .bold: return "**"
        case .italic: return "*"
        case .strikethrough: return "~~"
        case .code: return "`"
        // Markdown has no underline; the words still arrive, unmarked.
        case .underline: return ""
        }
    }

    static func inline(_ runs: [ComposeRun]) -> String {
        var out = ""
        var index = 0
        while index < runs.count {
            let link = runs[index].link
            var group: [ComposeRun] = []
            while index < runs.count, runs[index].link == link {
                group.append(runs[index])
                index += 1
            }
            let body = marked(group)
            out += link.map { "[\(body)](\($0))" } ?? body
        }
        return out
    }

    /// Opens and closes delimiters only where a mark actually starts or ends, so a bold phrase
    /// with one italic word inside reads `**a *b* c**` rather than a delimiter pair per run.
    private static func marked(_ runs: [ComposeRun]) -> String {
        var out = ""
        var open: [ComposeMark] = []
        func close(from position: Int) {
            for mark in open[position...].reversed() { out += delimiter(mark) }
            open.removeLast(open.count - position)
        }
        for run in runs {
            if case .lineBreak = run.content {
                out += "\n"
                continue
            }
            if let stale = open.firstIndex(where: { !run.marks.contains($0) }) { close(from: stale) }
            for mark in markOrder where run.marks.contains(mark) && !open.contains(mark) {
                out += delimiter(mark)
                open.append(mark)
            }
            switch run.content {
            case .text(let value): out += value
            case .image(let ref): out += "![\(ref.alt ?? "")](cid:\(ref.contentId))"
            case .lineBreak: break
            }
        }
        close(from: 0)
        return out
    }
}
