import Foundation

/// One control on the composer's format panel — every item the web editor's toolbar offers, plus
/// indent and outdent, which the web reaches with Tab and a phone keyboard has no key for.
public enum ComposeFormatItem: String, CaseIterable, Sendable {
    case bold, italic, underline, strikethrough
    case bulletList, numberedList, checklist
    case quote, codeBlock, outdent, indent
    case clearFormatting

    /// The panel's layout, row by row.
    public static let rows: [[ComposeFormatItem]] = [
        [.bold, .italic, .underline, .strikethrough],
        [.bulletList, .numberedList, .checklist],
        [.quote, .codeBlock, .outdent, .indent],
        [.clearFormatting],
    ]

    public var title: String {
        switch self {
        case .bold: return "Bold"
        case .italic: return "Italic"
        case .underline: return "Underline"
        case .strikethrough: return "Strikethrough"
        case .bulletList: return "Bulleted List"
        case .numberedList: return "Numbered List"
        case .checklist: return "Checklist"
        case .quote: return "Quote"
        case .codeBlock: return "Code Block"
        case .outdent: return "Decrease Indent"
        case .indent: return "Increase Indent"
        case .clearFormatting: return "Clear Formatting"
        }
    }

    public var symbol: String {
        switch self {
        case .bold: return "bold"
        case .italic: return "italic"
        case .underline: return "underline"
        case .strikethrough: return "strikethrough"
        case .bulletList: return "list.bullet"
        case .numberedList: return "list.number"
        case .checklist: return "checklist"
        case .quote: return "text.quote"
        case .codeBlock: return "curlybraces"
        case .outdent: return "decrease.indent"
        case .indent: return "increase.indent"
        case .clearFormatting: return "eraser"
        }
    }

    public func isActive(in state: ComposeFormatState) -> Bool {
        switch self {
        case .bold: return state.marks.contains(.bold)
        case .italic: return state.marks.contains(.italic)
        case .underline: return state.marks.contains(.underline)
        case .strikethrough: return state.marks.contains(.strikethrough)
        case .bulletList: return state.block.listKind == .bullet
        case .numberedList: return state.block.listKind == .ordered
        case .checklist: return state.block.listKind == .checklist
        case .quote: return state.block == .quote
        case .codeBlock: return state.block == .codeBlock
        case .outdent, .indent, .clearFormatting: return false
        }
    }

    public func apply(
        to text: NSMutableAttributedString, selection: NSRange, typing: inout ComposeFormatting.Attributes
    ) {
        switch self {
        case .bold: ComposeFormatting.toggleMark(.bold, in: text, selection: selection, typing: &typing)
        case .italic: ComposeFormatting.toggleMark(.italic, in: text, selection: selection, typing: &typing)
        case .underline: ComposeFormatting.toggleMark(.underline, in: text, selection: selection, typing: &typing)
        case .strikethrough:
            ComposeFormatting.toggleMark(.strikethrough, in: text, selection: selection, typing: &typing)
        case .bulletList: ComposeFormatting.toggleList(.bullet, in: text, selection: selection, typing: &typing)
        case .numberedList: ComposeFormatting.toggleList(.ordered, in: text, selection: selection, typing: &typing)
        case .checklist: ComposeFormatting.toggleList(.checklist, in: text, selection: selection, typing: &typing)
        case .quote: ComposeFormatting.toggleBlock(.quote, in: text, selection: selection, typing: &typing)
        case .codeBlock: ComposeFormatting.toggleBlock(.codeBlock, in: text, selection: selection, typing: &typing)
        case .outdent: ComposeFormatting.changeIndent(by: -1, in: text, selection: selection, typing: &typing)
        case .indent: ComposeFormatting.changeIndent(by: 1, in: text, selection: selection, typing: &typing)
        case .clearFormatting: ComposeFormatting.clearFormatting(in: text, selection: selection, typing: &typing)
        }
    }
}
