import MailVerdictKit
import UIKit

/// Turns the composer's semantic attributes into what the text view draws: fonts, colours, list
/// markers, attachments. Nothing reads these presentation attributes back — the document always
/// comes from the semantic keys — so restyling a range is always safe to repeat.
@MainActor
struct ComposeStyler {

    /// The image behind an inline image's content id.
    let image: (String) -> UIImage?

    static let listIndent: CGFloat = 26
    static let quoteIndent: CGFloat = 14

    /// Presentation attributes a run may or may not have; cleared before each restyle so a
    /// removed mark takes its look with it.
    private static let optionalKeys: [NSAttributedString.Key] = [
        .backgroundColor, .underlineStyle, .strikethroughStyle, .link,
    ]

    /// What the next keystroke carries: the semantic attributes plus their look. Image keys are
    /// dropped — a character typed after an image is text.
    func typingAttributes(_ semantic: ComposeFormatting.Attributes) -> [NSAttributedString.Key: Any] {
        var result = semantic
        result[.mvImage] = nil
        result[.mvImageWidth] = nil
        result[.mvImageAlt] = nil
        let block = ComposeAttributedCodec.block(in: semantic) ?? .paragraph
        let presentation = presentation(
            marks: ComposeAttributedCodec.marks(in: semantic), link: semantic[.mvLink] as? String, block: block)
        result.merge(presentation) { _, new in new }
        result[.paragraphStyle] = paragraphStyle(for: block, previous: nil)
        return result
    }

    /// Restyles every paragraph `range` touches. A list is restyled whole — ordered numbering
    /// counts paragraphs sharing one `NSTextList`, so a changed item can renumber its neighbours.
    func style(_ storage: NSMutableAttributedString, range: NSRange) {
        guard storage.length > 0 else { return }
        let start = min(max(range.location, 0), storage.length)
        let clamped = NSRange(location: start, length: min(range.length, storage.length - start))
        var paragraphs = ComposeFormatting.paragraphs(in: storage, covering: clamped)

        while let first = paragraphs.first, first.location > 0 {
            let previous = ComposeFormatting.paragraph(containing: first.location - 1, in: storage)
            guard isListItem(previous, in: storage) || isListItem(first, in: storage) else { break }
            guard isListItem(previous, in: storage) else { break }
            paragraphs.insert(previous, at: 0)
        }
        while let last = paragraphs.last, NSMaxRange(last) < storage.length {
            let next = ComposeFormatting.paragraph(containing: NSMaxRange(last), in: storage)
            guard isListItem(next, in: storage), next.length > 0 else { break }
            paragraphs.append(next)
        }

        var previousStyle: NSParagraphStyle?
        if let first = paragraphs.first, first.location > 0 {
            previousStyle =
                storage.attribute(.paragraphStyle, at: first.location - 1, effectiveRange: nil) as? NSParagraphStyle
        }
        for paragraph in paragraphs where paragraph.length > 0 {
            let kind = ComposeAttributedCodec.blockKind(at: NSMaxRange(paragraph) - 1, in: storage) ?? .paragraph
            let style = paragraphStyle(for: kind, previous: kind.listKind == nil ? nil : previousStyle)
            storage.addAttribute(.paragraphStyle, value: style, range: paragraph)
            previousStyle = style
            storage.enumerateAttributes(in: paragraph, options: []) { attributes, run, _ in
                for key in Self.optionalKeys { storage.removeAttribute(key, range: run) }
                storage.addAttributes(
                    presentation(
                        marks: ComposeAttributedCodec.marks(in: attributes), link: attributes[.mvLink] as? String,
                        block: kind),
                    range: run)
                if let contentId = attributes[.mvImage] as? String {
                    let width = attributes[.mvImageWidth] as? String
                    let existing = attributes[.attachment] as? ComposeImageAttachment
                    if existing?.contentId != contentId || existing?.widthSetting != width {
                        storage.addAttribute(
                            .attachment,
                            value: ComposeImageAttachment(
                                contentId: contentId, image: image(contentId), widthSetting: width),
                            range: run)
                    }
                } else if attributes[.attachment] != nil {
                    storage.removeAttribute(.attachment, range: run)
                }
            }
        }
    }

    private func isListItem(_ paragraph: NSRange, in storage: NSAttributedString) -> Bool {
        guard paragraph.length > 0 else { return false }
        return ComposeAttributedCodec.blockKind(at: NSMaxRange(paragraph) - 1, in: storage)?.listKind != nil
    }

    func presentation(marks: Set<ComposeMark>, link: String?, block: ComposeBlockKind) -> [NSAttributedString.Key: Any]
    {
        var result: [NSAttributedString.Key: Any] = [
            .font: font(marks: marks, block: block),
            .foregroundColor: block == .quote ? UIColor.secondaryLabel : UIColor.label,
        ]
        if marks.contains(.underline) { result[.underlineStyle] = NSUnderlineStyle.single.rawValue }
        if marks.contains(.strikethrough) { result[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
        if marks.contains(.code) || block == .codeBlock { result[.backgroundColor] = UIColor.secondarySystemFill }
        if let link, let url = URL(string: link) { result[.link] = url }
        return result
    }

    private func font(marks: Set<ComposeMark>, block: ComposeBlockKind) -> UIFont {
        let base: UIFont
        var bold = marks.contains(.bold)
        switch block {
        case .heading(let level):
            let style: UIFont.TextStyle =
                level == 1 ? .title1 : (level == 2 ? .title2 : (level == 3 ? .title3 : .headline))
            base = UIFont.preferredFont(forTextStyle: style)
            bold = true
        case .codeBlock:
            base = Self.monospaced
        default:
            base = marks.contains(.code) ? Self.monospaced : UIFont.preferredFont(forTextStyle: .body)
        }
        var traits = base.fontDescriptor.symbolicTraits
        if bold { traits.insert(.traitBold) }
        if marks.contains(.italic) { traits.insert(.traitItalic) }
        guard let descriptor = base.fontDescriptor.withSymbolicTraits(traits) else { return base }
        return UIFont(descriptor: descriptor, size: 0)
    }

    private static var monospaced: UIFont {
        UIFontMetrics(forTextStyle: .body).scaledFont(for: .monospacedSystemFont(ofSize: 15, weight: .regular))
    }

    /// List items carry one `NSTextList` per nesting level; TextKit 2 draws the markers. Lists
    /// are taken over from the paragraph above wherever they match, so consecutive items belong
    /// to the same list and number on from each other.
    func paragraphStyle(for kind: ComposeBlockKind, previous: NSParagraphStyle?) -> NSParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.paragraphSpacing = 2
        switch kind {
        case .listItem(let listKind, let level, let checked):
            let inherited = previous?.textLists ?? []
            var lists: [NSTextList] = []
            for depth in 0...level {
                let format = depth == level ? markerFormat(listKind, level: level, checked: checked) : nil
                if depth < inherited.count, format == nil || inherited[depth].markerFormat == format {
                    lists.append(inherited[depth])
                } else {
                    lists.append(NSTextList(markerFormat: format ?? .disc, options: 0))
                }
            }
            style.textLists = lists
            style.headIndent = Self.listIndent * CGFloat(level + 1)
            style.firstLineHeadIndent = style.headIndent
        case .quote:
            style.headIndent = Self.quoteIndent
            style.firstLineHeadIndent = Self.quoteIndent
        case .heading:
            style.paragraphSpacingBefore = 6
        case .paragraph, .codeBlock:
            break
        }
        return style
    }

    private func markerFormat(_ kind: ComposeListKind, level: Int, checked: Bool) -> NSTextList.MarkerFormat {
        switch kind {
        case .bullet: return level == 0 ? .disc : (level == 1 ? .circle : .square)
        case .ordered: return .decimal
        case .checklist: return checked ? .check : .box
        }
    }
}

/// An inline image, sized by the width the image menu chose: a pixel width or a percentage of
/// the line, never wider than the line itself.
final class ComposeImageAttachment: NSTextAttachment {
    let contentId: String
    let widthSetting: String?

    init(contentId: String, image: UIImage?, widthSetting: String?) {
        self.contentId = contentId
        self.widthSetting = widthSetting
        super.init(data: nil, ofType: nil)
        self.image = image
    }

    required init?(coder: NSCoder) {
        nil
    }

    override func attachmentBounds(
        for attributes: [NSAttributedString.Key: Any], location: any NSTextLocation, textContainer: NSTextContainer?,
        proposedLineFragment: CGRect, position: CGPoint
    ) -> CGRect {
        guard let image, image.size.width > 0 else { return CGRect(x: 0, y: 0, width: 24, height: 24) }
        let available = max(proposedLineFragment.width, 1)
        var width = min(image.size.width, available)
        if let setting = widthSetting {
            if setting.hasSuffix("%"), let percent = Double(setting.dropLast()) {
                width = available * CGFloat(percent) / 100
            } else if let pixels = Double(setting) {
                width = min(CGFloat(pixels), available)
            }
        }
        return CGRect(x: 0, y: 0, width: width, height: width * image.size.height / image.size.width)
    }
}
