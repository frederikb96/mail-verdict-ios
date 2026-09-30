import Foundation

/// One run of an order summary's text -- `bold` for a `**...**` span, plain otherwise.
public struct OrderSummaryInline: Equatable, Sendable {
    public let text: String
    public let bold: Bool

    public init(text: String, bold: Bool) {
        self.text = text
        self.bold = bold
    }
}

/// One block of an order summary -- a paragraph, or a run of bullet items.
public enum OrderSummaryBlock: Equatable, Sendable {
    case paragraph([OrderSummaryInline])
    case bullets([[OrderSummaryInline]])
}

/// Parses an order's `summary` field -- the same small markdown subset the server ever writes
/// (`orders/text.py`'s own write prompt), never a general-purpose renderer: a blank line breaks a
/// paragraph, a line starting `- ` or `* ` is a bullet, `**text**` is bold. Everything else,
/// including `#`, `[`, `<` and a bare URL, is plain text -- no heading, link or emphasis markup is
/// ever produced, since the model is never asked to write any.
public enum OrderSummaryDocument {

    public static func parse(_ text: String) -> [OrderSummaryBlock] {
        var blocks: [OrderSummaryBlock] = []
        var paragraphLines: [String] = []
        var bulletLines: [String] = []

        func flushParagraph() {
            guard !paragraphLines.isEmpty else { return }
            blocks.append(.paragraph(parseInline(paragraphLines.joined(separator: " "))))
            paragraphLines = []
        }
        func flushBullets() {
            guard !bulletLines.isEmpty else { return }
            blocks.append(.bullets(bulletLines.map(parseInline)))
            bulletLines = []
        }

        for line in text.components(separatedBy: "\n") {
            if line.trimmingCharacters(in: .whitespaces).isEmpty {
                flushParagraph()
                flushBullets()
            } else if line.hasPrefix("- ") || line.hasPrefix("* ") {
                flushParagraph()
                bulletLines.append(String(line.dropFirst(2)))
            } else {
                flushBullets()
                paragraphLines.append(line)
            }
        }
        flushParagraph()
        flushBullets()
        return blocks
    }

    /// Splits one line on `**bold**` spans -- an unmatched opening `**` is kept as literal text
    /// rather than swallowed, since the model's own output is never guaranteed to balance.
    static func parseInline(_ line: String) -> [OrderSummaryInline] {
        var inlines: [OrderSummaryInline] = []
        var remaining = Substring(line)
        while let openRange = remaining.range(of: "**") {
            let before = remaining[remaining.startIndex..<openRange.lowerBound]
            if !before.isEmpty { inlines.append(OrderSummaryInline(text: String(before), bold: false)) }
            let afterOpen = remaining[openRange.upperBound...]
            guard let closeRange = afterOpen.range(of: "**") else {
                inlines.append(OrderSummaryInline(text: "**", bold: false))
                remaining = afterOpen
                continue
            }
            let bold = afterOpen[afterOpen.startIndex..<closeRange.lowerBound]
            inlines.append(OrderSummaryInline(text: String(bold), bold: true))
            remaining = afterOpen[closeRange.upperBound...]
        }
        if !remaining.isEmpty { inlines.append(OrderSummaryInline(text: String(remaining), bold: false)) }
        return inlines
    }
}
