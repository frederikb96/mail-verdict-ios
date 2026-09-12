import Foundation

/// What the format panel shows as active at the current selection.
public struct ComposeFormatState: Equatable, Sendable {
    public var marks: Set<ComposeMark>
    public var block: ComposeBlockKind
    public var link: String?

    public init(marks: Set<ComposeMark> = [], block: ComposeBlockKind = .paragraph, link: String? = nil) {
        self.marks = marks
        self.block = block
        self.link = link
    }
}

/// The editor's formatting commands, as edits to semantic attributes on a mutable attributed
/// string — the text view's own storage in the app, a plain `NSMutableAttributedString` in tests.
/// Each command also returns the typing attributes the next keystroke should carry, since an
/// empty selection has no characters to format.
///
/// A paragraph's kind is read from its last character (its terminating newline when it has one),
/// the same rule `ComposeAttributedCodec` reads it back with, so a command and a later read-back
/// always agree about which paragraph is which.
public enum ComposeFormatting {

    public typealias Attributes = [NSAttributedString.Key: Any]

    // MARK: - Paragraphs

    /// The paragraph containing `location`, including its terminating newline when it has one. At
    /// the very end of text ending in a newline this is the empty last paragraph.
    public static func paragraph(containing location: Int, in text: NSAttributedString) -> NSRange {
        let string = NSString(string: text.string)
        let length = string.length
        let clamped = min(max(location, 0), length)
        let before = string.range(of: "\n", options: .backwards, range: NSRange(location: 0, length: clamped))
        let start = before.location == NSNotFound ? 0 : before.location + 1
        let after = string.range(of: "\n", options: [], range: NSRange(location: start, length: length - start))
        let end = after.location == NSNotFound ? length : after.location + 1
        return NSRange(location: start, length: end - start)
    }

    public static func paragraphs(in text: NSAttributedString, covering range: NSRange) -> [NSRange] {
        var current = paragraph(containing: range.location, in: text)
        var result = [current]
        while NSMaxRange(current) < NSMaxRange(range) {
            current = paragraph(containing: NSMaxRange(current), in: text)
            result.append(current)
        }
        return result
    }

    /// The paragraph without its terminating newline.
    public static func content(of paragraph: NSRange, in text: NSAttributedString) -> NSRange {
        guard paragraph.length > 0 else { return paragraph }
        let string = NSString(string: text.string)
        let lastIsNewline = string.character(at: NSMaxRange(paragraph) - 1) == 0x0A
        return NSRange(location: paragraph.location, length: paragraph.length - (lastIsNewline ? 1 : 0))
    }

    public static func blockKind(
        ofParagraph paragraph: NSRange, in text: NSAttributedString, typing: Attributes
    ) -> ComposeBlockKind {
        if paragraph.length > 0 {
            return ComposeAttributedCodec.blockKind(at: NSMaxRange(paragraph) - 1, in: text) ?? .paragraph
        }
        return ComposeAttributedCodec.block(in: typing) ?? .paragraph
    }

    /// Makes every character of each paragraph in `range` carry the paragraph's kind. After an
    /// edit a character typed at a paragraph's start carries the previous paragraph's kind (text
    /// views copy the attributes of the character before the caret); this puts it right.
    public static func normalizeBlocks(in text: NSMutableAttributedString, range: NSRange, typing: Attributes) {
        guard text.length > 0 else { return }
        for paragraph in paragraphs(in: text, covering: range) where paragraph.length > 0 {
            let kind = blockKind(ofParagraph: paragraph, in: text, typing: typing)
            text.addAttribute(.mvBlock, value: kind.attributeValue, range: paragraph)
        }
    }

    // MARK: - State

    public static func formatState(
        in text: NSAttributedString, selection: NSRange, typing: Attributes
    ) -> ComposeFormatState {
        let caret = paragraph(containing: selection.location, in: text)
        let block = blockKind(ofParagraph: caret, in: text, typing: typing)
        guard selection.length > 0 else {
            return ComposeFormatState(
                marks: ComposeAttributedCodec.marks(in: typing), block: block, link: typing[.mvLink] as? String)
        }
        let marks = ComposeMark.allCases.filter { everyCharacter(in: selection, of: text, has: $0) }
        let link = text.attribute(.mvLink, at: selection.location, effectiveRange: nil) as? String
        return ComposeFormatState(marks: Set(marks), block: block, link: link)
    }

    /// Newlines are ignored: a selection spanning two bold paragraphs is bold, whatever the
    /// separator between them carries.
    private static func everyCharacter(in range: NSRange, of text: NSAttributedString, has mark: ComposeMark) -> Bool {
        let string = NSString(string: text.string)
        var result = true
        text.enumerateAttribute(ComposeAttributedCodec.key(for: mark), in: range, options: []) {
            value, subrange, stop in
            if string.substring(with: subrange).allSatisfy({ $0 == "\n" }) { return }
            if (value as? Bool) != true {
                result = false
                stop.pointee = true
            }
        }
        return result
    }

    // MARK: - Marks

    /// On a selection: applies the mark unless every selected character already has it, in which
    /// case it removes it. On a caret: flips it for the next keystroke.
    public static func toggleMark(
        _ mark: ComposeMark, in text: NSMutableAttributedString, selection: NSRange, typing: inout Attributes
    ) {
        let key = ComposeAttributedCodec.key(for: mark)
        guard selection.length > 0 else {
            typing[key] = (typing[key] as? Bool) == true ? nil : true
            return
        }
        if everyCharacter(in: selection, of: text, has: mark) {
            text.removeAttribute(key, range: selection)
            typing[key] = nil
        } else {
            text.addAttribute(key, value: true, range: selection)
            typing[key] = true
        }
    }

    /// Removes every mark and link from the selection and turns its paragraphs back into plain
    /// ones — the web toolbar's "Clear formatting".
    public static func clearFormatting(
        in text: NSMutableAttributedString, selection: NSRange, typing: inout Attributes
    ) {
        let inlineKeys = ComposeMark.allCases.map(ComposeAttributedCodec.key(for:)) + [.mvLink]
        if selection.length > 0 {
            for key in inlineKeys { text.removeAttribute(key, range: selection) }
        }
        for key in inlineKeys { typing[key] = nil }
        transformBlocks(in: text, selection: selection, typing: &typing) { _ in .paragraph }
    }

    // MARK: - Blocks

    /// Turns every selected paragraph into a list of `kind`, or — when all of them already are
    /// one — back into plain paragraphs.
    public static func toggleList(
        _ kind: ComposeListKind, in text: NSMutableAttributedString, selection: NSRange, typing: inout Attributes
    ) {
        let allAlready = paragraphs(in: text, covering: selection).allSatisfy {
            blockKind(ofParagraph: $0, in: text, typing: typing).listKind == kind
        }
        transformBlocks(in: text, selection: selection, typing: &typing) { current in
            if allAlready { return .paragraph }
            if case .listItem(let existing, let level, let checked) = current {
                return .listItem(kind, level: level, checked: existing == .checklist && kind == .checklist && checked)
            }
            return .listItem(kind, level: 0, checked: false)
        }
    }

    /// Quote, code block or heading on or off for the selected paragraphs.
    public static func toggleBlock(
        _ target: ComposeBlockKind, in text: NSMutableAttributedString, selection: NSRange, typing: inout Attributes
    ) {
        let allAlready = paragraphs(in: text, covering: selection).allSatisfy {
            blockKind(ofParagraph: $0, in: text, typing: typing) == target
        }
        transformBlocks(in: text, selection: selection, typing: &typing) { _ in allAlready ? .paragraph : target }
    }

    /// Nests or un-nests the selected list items. A list item never goes more than one level
    /// deeper than the item above it, since nothing could express the level it skipped.
    public static func changeIndent(
        by delta: Int, in text: NSMutableAttributedString, selection: NSRange, typing: inout Attributes
    ) {
        for paragraph in paragraphs(in: text, covering: selection) {
            guard
                case .listItem(let kind, let level, let checked) = blockKind(
                    ofParagraph: paragraph, in: text, typing: typing)
            else { continue }
            var ceiling = 0
            if paragraph.location > 0 {
                let previous = self.paragraph(containing: paragraph.location - 1, in: text)
                if let previousLevel = blockKind(ofParagraph: previous, in: text, typing: typing).listLevel {
                    ceiling = previousLevel + 1
                }
            }
            let next = min(max(level + delta, 0), min(ceiling, ComposeBlockKind.maxListLevel))
            apply(.listItem(kind, level: next, checked: checked), to: paragraph, in: text, typing: &typing)
        }
    }

    /// Ticks or unticks the checklist item containing `location`; a no-op anywhere else.
    public static func toggleChecked(at location: Int, in text: NSMutableAttributedString, typing: inout Attributes) {
        let target = paragraph(containing: location, in: text)
        guard
            case .listItem(.checklist, let level, let checked) = blockKind(
                ofParagraph: target, in: text, typing: typing)
        else { return }
        apply(.listItem(.checklist, level: level, checked: !checked), to: target, in: text, typing: &typing)
    }

    public static func setBlock(
        _ kind: ComposeBlockKind, forParagraphAt location: Int, in text: NSMutableAttributedString,
        typing: inout Attributes
    ) {
        apply(kind, to: paragraph(containing: location, in: text), in: text, typing: &typing)
    }

    private static func transformBlocks(
        in text: NSMutableAttributedString, selection: NSRange, typing: inout Attributes,
        _ transform: (ComposeBlockKind) -> ComposeBlockKind
    ) {
        for paragraph in paragraphs(in: text, covering: selection) {
            let next = transform(blockKind(ofParagraph: paragraph, in: text, typing: typing))
            apply(next, to: paragraph, in: text, typing: &typing)
        }
        let caret = paragraph(containing: selection.location, in: text)
        typing[.mvBlock] = blockKind(ofParagraph: caret, in: text, typing: typing).attributeValue
    }

    /// An empty last paragraph has no character to carry its kind, so it lives in the typing
    /// attributes instead.
    private static func apply(
        _ kind: ComposeBlockKind, to paragraph: NSRange, in text: NSMutableAttributedString, typing: inout Attributes
    ) {
        if paragraph.length > 0 {
            text.addAttribute(.mvBlock, value: kind.attributeValue, range: paragraph)
        } else {
            typing[.mvBlock] = kind.attributeValue
        }
    }

    // MARK: - Links

    /// The link under or just before `location` — the range a caret inside a link edits.
    public static func linkRange(at location: Int, in text: NSAttributedString) -> NSRange? {
        let whole = NSRange(location: 0, length: text.length)
        for probe in [location, location - 1] where probe >= 0 && probe < text.length {
            var range = NSRange(location: 0, length: 0)
            if text.attribute(.mvLink, at: probe, longestEffectiveRange: &range, in: whole) != nil {
                return range
            }
        }
        return nil
    }

    /// Links the selection (or the link the caret sits in) to `url`; an empty or `nil` URL
    /// removes the link. With nothing selected and no link to edit, the URL itself is inserted as
    /// the link's text. Returns the selection the editor should show afterwards.
    public static func setLink(
        _ url: String?, in text: NSMutableAttributedString, selection: NSRange, typing: inout Attributes
    ) -> NSRange {
        var target = selection
        if target.length == 0, let existing = linkRange(at: selection.location, in: text) { target = existing }
        let value = url?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !value.isEmpty else {
            if target.length > 0 { text.removeAttribute(.mvLink, range: target) }
            typing[.mvLink] = nil
            return selection
        }
        guard target.length > 0 else {
            var attributes = typing
            attributes[.mvLink] = value
            text.insert(NSAttributedString(string: value, attributes: attributes), at: selection.location)
            typing[.mvLink] = nil
            return NSRange(location: selection.location + NSString(string: value).length, length: 0)
        }
        text.addAttribute(.mvLink, value: value, range: target)
        return target
    }

    // MARK: - Return and Backspace

    /// Return in an empty list item, quote, heading or code line leaves that format (a nested list
    /// item steps out one level) instead of adding another empty one. Returns true when it did, and
    /// the newline must not be inserted.
    public static func handleReturn(
        in text: NSMutableAttributedString, selection: NSRange, typing: inout Attributes
    ) -> Bool {
        guard selection.length == 0 else { return false }
        let current = paragraph(containing: selection.location, in: text)
        guard content(of: current, in: text).length == 0 else { return false }
        let next: ComposeBlockKind
        switch blockKind(ofParagraph: current, in: text, typing: typing) {
        case .paragraph: return false
        case .listItem(let kind, let level, _) where level > 0: next = .listItem(kind, level: level - 1, checked: false)
        case .listItem, .quote, .codeBlock, .heading: next = .paragraph
        }
        apply(next, to: current, in: text, typing: &typing)
        typing[.mvBlock] = next.attributeValue
        return true
    }

    /// After a newline was inserted at `newlineLocation`: the paragraph that starts after it gets
    /// the kind a new paragraph should have — a checklist item starts unticked, and an empty line
    /// after a heading is body text again.
    public static func didInsertParagraphBreak(
        at newlineLocation: Int, in text: NSMutableAttributedString, typing: inout Attributes
    ) {
        guard let previous = ComposeAttributedCodec.blockKind(at: newlineLocation, in: text) else { return }
        let following = paragraph(containing: newlineLocation + 1, in: text)
        let next: ComposeBlockKind
        switch previous {
        case .heading:
            next = content(of: following, in: text).length == 0 ? .paragraph : previous
        case .listItem(let kind, let level, _):
            next = .listItem(kind, level: level, checked: false)
        case .paragraph, .quote, .codeBlock:
            next = previous
        }
        apply(next, to: following, in: text, typing: &typing)
        typing[.mvBlock] = next.attributeValue
    }

    /// Backspace at the very start of a formatted paragraph takes the format off (a nested list
    /// item steps out one level) rather than merging it into the paragraph above. `range` is the
    /// one character a text view is about to delete. Returns true when it did.
    public static func handleBackspace(
        deleting range: NSRange, in text: NSMutableAttributedString, typing: inout Attributes
    ) -> Bool {
        guard range.length == 1, range.location < text.length,
            NSString(string: text.string).character(at: range.location) == 0x0A
        else { return false }
        let following = paragraph(containing: range.location + 1, in: text)
        let next: ComposeBlockKind
        switch blockKind(ofParagraph: following, in: text, typing: typing) {
        case .paragraph: return false
        case .listItem(let kind, let level, let checked) where level > 0:
            next = .listItem(kind, level: level - 1, checked: checked)
        case .listItem, .quote, .codeBlock, .heading: next = .paragraph
        }
        apply(next, to: following, in: text, typing: &typing)
        typing[.mvBlock] = next.attributeValue
        return true
    }
}
