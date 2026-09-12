import Foundation
import SwiftSoup

/// Collapses an incoming reply's own quoted original — port of `collapseQuotedReply` in
/// `email-renderer.tsx`.
///
/// The web hides the quote behind a button with a click handler. Message pages here run no
/// script, so the quote goes inside a `<details>` element instead, which the web view expands and
/// collapses by itself; `EmailStyles` swaps the summary's label between "Show" and "Hide". The
/// wrap is applied by `MessageMarkupWriter` as it writes the body.
public enum QuoteCollapser {

    /// Class names real mail clients give a reply's quoted original (Gmail, Thunderbird, Yahoo
    /// Mail, ProtonMail), matched on the blockquote or a couple of its ancestors. Never a generic
    /// "quote": an editorial pull-quote carries no such class and must stay visible.
    private static let replyQuoteClassPattern =
        #"\b(?:gmail_quote|moz-cite-prefix|yahoo_quoted|protonmail_quote)\b"#
    static let ancestorDepth = 2

    /// Everything the wrap puts before the quote; `</details>` closes it. The visible "•••"
    /// matches Apple Mail's own disclosure for a folded quote; the two hidden spans are what a
    /// screen reader announces instead, CSS switching which one exists in the accessibility tree.
    static let openingMarkup =
        #"<details class="mv-quote"><summary class="mv-quote-toggle">"#
        + #"<span class="mv-quote-dots" aria-hidden="true">•••</span>"#
        + #"<span class="mv-quote-show mv-sr-only">Show quoted text</span>"#
        + #"<span class="mv-quote-hide mv-sr-only">Hide quoted text</span></summary>"#

    /// A body with its first reply quote collapsed and nothing else changed but sanitization.
    public static func collapse(_ html: String) -> String {
        MessageMarkupWriter.write(html, options: MessageMarkupOptions(collapsesReplyQuote: true))
    }

    /// `type="cite"` is the one signal nearly every client agrees on; the class check catches the
    /// messages that omit it.
    static func isReplyQuote(_ blockquote: Element, root: Element) -> Bool {
        if (try? blockquote.attr("type"))?.lowercased() == "cite" { return true }
        var node: Element? = blockquote
        var depth = 0
        while let current = node, current !== root, depth <= ancestorDepth {
            if let className = try? current.className(),
                className.range(of: replyQuoteClassPattern, options: [.regularExpression, .caseInsensitive]) != nil
            {
                return true
            }
            node = current.parent()
            depth += 1
        }
        return false
    }
}
