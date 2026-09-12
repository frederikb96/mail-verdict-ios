import Foundation

/// The semantic attributes the composer's text view carries. They say what a range *is* (bold, a
/// checklist item, an inline image) and nothing about how it looks — the app derives fonts and
/// paragraph styles from them, while everything that reads or rewrites the document works on these
/// keys alone, which is what keeps it testable without UIKit.
extension NSAttributedString.Key {
    public static var mvBold: NSAttributedString.Key { .init("MVComposeBold") }
    public static var mvItalic: NSAttributedString.Key { .init("MVComposeItalic") }
    public static var mvUnderline: NSAttributedString.Key { .init("MVComposeUnderline") }
    public static var mvStrikethrough: NSAttributedString.Key { .init("MVComposeStrikethrough") }
    public static var mvCode: NSAttributedString.Key { .init("MVComposeCode") }
    public static var mvLink: NSAttributedString.Key { .init("MVComposeLink") }
    /// The paragraph's block kind, as `ComposeBlockKind.attributeValue`. Carried by every
    /// character of the paragraph including its terminating newline.
    public static var mvBlock: NSAttributedString.Key { .init("MVComposeBlock") }
    /// On an attachment character: the inline image's content id.
    public static var mvImage: NSAttributedString.Key { .init("MVComposeImage") }
    public static var mvImageWidth: NSAttributedString.Key { .init("MVComposeImageWidth") }
    public static var mvImageAlt: NSAttributedString.Key { .init("MVComposeImageAlt") }
}

extension ComposeBlockKind {

    /// A string rather than the enum itself, so the value survives a text view copying its
    /// attributes around and compares by content wherever attribute runs are coalesced.
    public var attributeValue: String {
        switch self {
        case .paragraph: return "p"
        case .heading(let level): return "h\(level)"
        case .quote: return "quote"
        case .codeBlock: return "code"
        case .listItem(let kind, let level, let checked): return "\(kind.rawValue):\(level):\(checked ? 1 : 0)"
        }
    }

    public init?(attributeValue: String) {
        switch attributeValue {
        case "p": self = .paragraph
        case "quote": self = .quote
        case "code": self = .codeBlock
        default:
            if attributeValue.hasPrefix("h"), let level = Int(attributeValue.dropFirst()) {
                self = .heading(level: level)
                return
            }
            let parts = attributeValue.split(separator: ":")
            guard parts.count == 3, let kind = ComposeListKind(rawValue: String(parts[0])),
                let level = Int(parts[1])
            else { return nil }
            self = .listItem(kind, level: level, checked: parts[2] == "1")
        }
    }
}

/// `ComposeDocument` ⇄ attributed string. Paragraphs are separated by `\n`, a line break inside a
/// paragraph is U+2028, and an inline image is the object-replacement character carrying its
/// content id.
public enum ComposeAttributedCodec {

    public static let lineSeparator: Character = "\u{2028}"
    public static let attachmentCharacter: Character = "\u{FFFC}"

    public static var semanticKeys: [NSAttributedString.Key] {
        ComposeMark.allCases.map(key(for:)) + [.mvLink, .mvBlock, .mvImage, .mvImageWidth, .mvImageAlt]
    }

    public static func key(for mark: ComposeMark) -> NSAttributedString.Key {
        switch mark {
        case .bold: return .mvBold
        case .italic: return .mvItalic
        case .underline: return .mvUnderline
        case .strikethrough: return .mvStrikethrough
        case .code: return .mvCode
        }
    }

    public static func attributes(
        marks: Set<ComposeMark>, link: String?, block: ComposeBlockKind
    ) -> [NSAttributedString.Key: Any] {
        var attributes: [NSAttributedString.Key: Any] = [.mvBlock: block.attributeValue]
        for mark in marks { attributes[key(for: mark)] = true }
        if let link { attributes[.mvLink] = link }
        return attributes
    }

    public static func marks(in attributes: [NSAttributedString.Key: Any]) -> Set<ComposeMark> {
        Set(ComposeMark.allCases.filter { (attributes[key(for: $0)] as? Bool) == true })
    }

    public static func block(in attributes: [NSAttributedString.Key: Any]) -> ComposeBlockKind? {
        (attributes[.mvBlock] as? String).flatMap(ComposeBlockKind.init(attributeValue:))
    }

    /// The document as semantic attributes only. The last paragraph has no terminating newline,
    /// so an empty last paragraph has no character to carry its kind — a text view holds that in
    /// its typing attributes, and `document(from:trailingBlock:)` takes it back the same way.
    public static func attributedString(from document: ComposeDocument) -> NSMutableAttributedString {
        let result = NSMutableAttributedString(string: "")
        let blocks = document.normalized().blocks
        for (index, block) in blocks.enumerated() {
            for run in block.runs {
                var runAttributes = attributes(marks: run.marks, link: run.link, block: block.kind)
                switch run.content {
                case .text(let value):
                    result.append(NSAttributedString(string: value, attributes: runAttributes))
                case .lineBreak:
                    result.append(NSAttributedString(string: String(lineSeparator), attributes: runAttributes))
                case .image(let reference):
                    runAttributes[.mvImage] = reference.contentId
                    if let width = reference.width { runAttributes[.mvImageWidth] = width }
                    if let alt = reference.alt { runAttributes[.mvImageAlt] = alt }
                    result.append(NSAttributedString(string: String(attachmentCharacter), attributes: runAttributes))
                }
            }
            if index < blocks.count - 1 {
                result.append(NSAttributedString(string: "\n", attributes: [.mvBlock: block.kind.attributeValue]))
            }
        }
        return result
    }

    /// Reads the document back. A paragraph's kind comes from its terminating newline, which a
    /// keystroke at the paragraph's start never touches; the last paragraph, which has none,
    /// uses its last character, and an empty last paragraph uses `trailingBlock`.
    public static func document(
        from text: NSAttributedString, trailingBlock: ComposeBlockKind? = nil
    ) -> ComposeDocument {
        let string = NSString(string: text.string)
        let length = string.length
        var blocks: [ComposeBlock] = []
        var location = 0
        while true {
            let newline = string.range(
                of: "\n", options: [], range: NSRange(location: location, length: length - location))
            let contentEnd = newline.location == NSNotFound ? length : newline.location
            let content = NSRange(location: location, length: contentEnd - location)
            let kind: ComposeBlockKind
            if newline.location != NSNotFound {
                kind = blockKind(at: newline.location, in: text) ?? .paragraph
            } else if content.length > 0 {
                kind = blockKind(at: contentEnd - 1, in: text) ?? .paragraph
            } else {
                kind = trailingBlock ?? .paragraph
            }
            blocks.append(ComposeBlock(kind, runs(in: content, of: text, string: string)))
            if newline.location == NSNotFound { break }
            location = newline.location + 1
        }
        return ComposeDocument(blocks: blocks).normalized()
    }

    public static func blockKind(at location: Int, in text: NSAttributedString) -> ComposeBlockKind? {
        guard location >= 0, location < text.length else { return nil }
        return (text.attribute(.mvBlock, at: location, effectiveRange: nil) as? String)
            .flatMap(ComposeBlockKind.init(attributeValue:))
    }

    private static func runs(in range: NSRange, of text: NSAttributedString, string: NSString) -> [ComposeRun] {
        var runs: [ComposeRun] = []
        guard range.length > 0 else { return runs }
        text.enumerateAttributes(in: range, options: []) { attributes, subrange, _ in
            let marks = marks(in: attributes)
            let link = attributes[.mvLink] as? String
            var buffer = ""
            func flushBuffer() {
                if !buffer.isEmpty { runs.append(ComposeRun(.text(buffer), marks: marks, link: link)) }
                buffer = ""
            }
            for character in string.substring(with: subrange) {
                if character == lineSeparator {
                    flushBuffer()
                    runs.append(ComposeRun(.lineBreak, marks: marks, link: link))
                } else if character == attachmentCharacter {
                    flushBuffer()
                    // An attachment character with no content id is something the editor never
                    // made — nothing a submission could upload for it.
                    if let contentId = attributes[.mvImage] as? String {
                        let reference = ComposeImageRef(
                            contentId: contentId, width: attributes[.mvImageWidth] as? String,
                            alt: attributes[.mvImageAlt] as? String)
                        runs.append(ComposeRun(.image(reference), marks: marks, link: link))
                    }
                } else {
                    buffer.append(character)
                }
            }
            flushBuffer()
        }
        return runs
    }
}
