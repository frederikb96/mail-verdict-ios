import Foundation
import SwiftSoup

/// Which canvas a message body renders on.
public enum MVCanvas: String, Sendable, Equatable, Codable, CaseIterable {
    case light
    case dark

    public var toggled: MVCanvas { self == .dark ? .light : .dark }
}

/// The default canvas for an HTML body before any per-message choice. In the dark theme, a
/// message that declares its own dark-mode support opens dark; otherwise — per D15 — one with no
/// colour declaration anywhere opens dark too, like Apple Mail renders plain mail, because there
/// is nothing in it for a dark canvas to clash with. A message declaring any colour at all, by
/// any means, stays light: a dark canvas is never guaranteed to match whatever background such a
/// template assumed, so the safer failure is the one that is merely unsurprising rather than
/// unreadable.
public enum CanvasPicker {

    private static let darkModeMediaPattern = #"@media[^{]*prefers-color-scheme\s*:\s*dark"#
    private static let colorSchemeDarkPattern = #"color-scheme\s*:[^;"'}]*\bdark\b"#
    private static let cssColorDeclarationPattern = #"(?:^|[;{])\s*(?:color|background|background-color)\s*:"#

    /// Pre-CSS HTML painted colour with these attributes; a newsletter old enough still can.
    private static let legacyColorAttributes = ["bgcolor", "color", "text", "link", "vlink", "alink"]

    public static func pickCanvas(html: String?, theme: MVCanvas) -> MVCanvas {
        guard let html, !html.isEmpty, theme == .dark else { return theme }
        if declaresDarkModeSupport(html) { return .dark }
        return declaresAnyColor(html) ? .light : .dark
    }

    static func declaresDarkModeSupport(_ html: String) -> Bool {
        matches(darkModeMediaPattern, in: html) || matches(colorSchemeDarkPattern, in: html)
    }

    /// Whether the body declares a colour anywhere — an inline `style`, a `<style>` block rule,
    /// or a legacy attribute — at any depth. Unlike the dark-mode check above, there is no "too
    /// deep to count": one styled span several levels in is still evidence the author planned a
    /// colour scheme the template cannot be trusted to fit on a canvas it never saw.
    static func declaresAnyColor(_ html: String) -> Bool {
        guard let document = try? SwiftSoup.parseBodyFragment(html), let body = document.body() else {
            return false
        }
        if let styles = try? body.select("style") {
            for style in styles.array() where matches(cssColorDeclarationPattern, in: style.data()) {
                return true
            }
        }
        return hasColorAttribute(body)
    }

    private static func hasColorAttribute(_ element: Element) -> Bool {
        if let style = try? element.attr("style"), matches(cssColorDeclarationPattern, in: style) {
            return true
        }
        if legacyColorAttributes.contains(where: { element.hasAttr($0) }) {
            return true
        }
        return element.children().contains { hasColorAttribute($0) }
    }

    private static func matches(_ pattern: String, in text: String) -> Bool {
        text.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil
    }
}
