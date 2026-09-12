import Foundation

/// A character-level format the composer can apply. The web editor's toolbar offers the first
/// four; `code` only ever arrives through paste or a reopened draft, and is kept so neither loses
/// it.
public enum ComposeMark: String, Codable, Sendable, CaseIterable {
    case bold, italic, underline, strikethrough, code
}

public enum ComposeListKind: String, Codable, Sendable, CaseIterable {
    case bullet, ordered, checklist
}

/// What one paragraph of the composer body is. A list item carries its own nesting level rather
/// than living inside a list container, because that is how a text view holds it: one paragraph,
/// one set of paragraph attributes.
public enum ComposeBlockKind: Hashable, Codable, Sendable {
    case paragraph
    case heading(level: Int)
    case listItem(ComposeListKind, level: Int, checked: Bool)
    case quote
    case codeBlock

    public static let maxListLevel = 5

    public var listKind: ComposeListKind? {
        if case .listItem(let kind, _, _) = self { return kind }
        return nil
    }

    public var listLevel: Int? {
        if case .listItem(_, let level, _) = self { return level }
        return nil
    }
}

/// An inline image by reference: the bytes live in the composer's inline-image store, keyed by
/// the same content id the HTML's `cid:` source and the multipart upload use.
public struct ComposeImageRef: Hashable, Codable, Sendable {
    public var contentId: String
    /// The HTML `width` attribute as written — a pixel count or a percentage.
    public var width: String?
    public var alt: String?

    public init(contentId: String, width: String? = nil, alt: String? = nil) {
        self.contentId = contentId
        self.width = width
        self.alt = alt
    }
}

public enum ComposeInline: Hashable, Codable, Sendable {
    case text(String)
    /// A line break inside one paragraph — `<br>` in HTML.
    case lineBreak
    case image(ComposeImageRef)
}

public struct ComposeRun: Hashable, Codable, Sendable {
    public var content: ComposeInline
    public var marks: Set<ComposeMark>
    public var link: String?

    public init(_ content: ComposeInline, marks: Set<ComposeMark> = [], link: String? = nil) {
        self.content = content
        self.marks = marks
        self.link = link
    }

    public static func text(_ value: String, _ marks: Set<ComposeMark> = [], link: String? = nil) -> ComposeRun {
        ComposeRun(.text(value), marks: marks, link: link)
    }
}

public struct ComposeBlock: Hashable, Codable, Sendable {
    public var kind: ComposeBlockKind
    public var runs: [ComposeRun]

    public init(_ kind: ComposeBlockKind = .paragraph, _ runs: [ComposeRun] = []) {
        self.kind = kind
        self.runs = runs
    }

    /// The block's text with every image and format dropped — what a code block serializes, and
    /// what an emptiness check reads.
    public var plainText: String {
        runs.map { run -> String in
            switch run.content {
            case .text(let value): return value
            case .lineBreak: return "\n"
            case .image: return ""
            }
        }.joined()
    }
}

/// The composer body: an ordered list of paragraphs. Every producer (the HTML parser, the
/// attributed-string codec) hands back a `normalized()` document, so two documents describing the
/// same content compare equal — which is what the composer's dirty check relies on.
public struct ComposeDocument: Hashable, Codable, Sendable {
    public var blocks: [ComposeBlock]

    public init(blocks: [ComposeBlock]) {
        self.blocks = blocks
    }

    public static var empty: ComposeDocument { ComposeDocument(blocks: [ComposeBlock()]) }

    /// True when there is nothing a recipient would see — no image, and no text beyond
    /// whitespace. Empty paragraphs typed as spacing still count as empty.
    public var isEmpty: Bool {
        blocks.allSatisfy { block in
            block.runs.allSatisfy { run in
                switch run.content {
                case .text(let value): return value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                case .lineBreak: return true
                case .image: return false
                }
            }
        }
    }

    /// Every inline image's content id, in document order, each once — the set a submission
    /// uploads, so an image deleted from the body is never sent.
    public var referencedContentIds: [String] {
        var seen = Set<String>()
        var result: [String] = []
        for block in blocks {
            for run in block.runs {
                if case .image(let ref) = run.content, seen.insert(ref.contentId).inserted {
                    result.append(ref.contentId)
                }
            }
        }
        return result
    }

    /// Merges adjacent runs that format identically, drops empty text, clamps levels into range,
    /// and strips formatting a code block cannot carry. A list item never sits more than one level
    /// deeper than the item before it, since no markup can express the skipped level.
    public func normalized() -> ComposeDocument {
        var result: [ComposeBlock] = []
        for block in blocks {
            var kind = block.kind
            switch kind {
            case .heading(let level):
                kind = .heading(level: min(max(level, 1), 6))
            case .listItem(let listKind, let level, let checked):
                let previousLevel = result.last?.kind.listLevel
                let ceiling = previousLevel.map { $0 + 1 } ?? 0
                let clamped = min(max(level, 0), min(ceiling, ComposeBlockKind.maxListLevel))
                kind = .listItem(listKind, level: clamped, checked: listKind == .checklist && checked)
            case .paragraph, .quote, .codeBlock:
                break
            }

            var runs: [ComposeRun] = []
            for var run in block.runs {
                if kind == .codeBlock {
                    if case .image = run.content { continue }
                    run.marks = []
                    run.link = nil
                }
                if case .text(let value) = run.content {
                    if value.isEmpty { continue }
                    if let last = runs.last, case .text(let previous) = last.content,
                        last.marks == run.marks, last.link == run.link
                    {
                        runs[runs.count - 1].content = .text(previous + value)
                        continue
                    }
                }
                runs.append(run)
            }
            result.append(ComposeBlock(kind, runs))
        }
        if result.isEmpty { result = [ComposeBlock()] }
        return ComposeDocument(blocks: result)
    }
}
