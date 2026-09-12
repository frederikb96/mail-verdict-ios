import Foundation
import SwiftSoup

/// Which canvas a message body renders on.
public enum MVCanvas: String, Sendable, Equatable, Codable, CaseIterable {
    case light
    case dark

    public var toggled: MVCanvas { self == .dark ? .light : .dark }
}

/// The default canvas for an HTML body before any per-message choice — port of `pickCanvas` in
/// the web's `email-renderer.tsx`, whose doc comments carry the reasoning. In short: the light
/// theme is always light; in the dark theme a message that declares its own dark-mode support
/// opens dark, and otherwise only one whose root-level colours read safely on either canvas
/// does. Every doubtful case fails towards light, because the wrong guess there is merely
/// disappointing where the opposite one is unreadable.
public enum CanvasPicker {

    private static let darkModeMediaPattern = #"@media[^{]*prefers-color-scheme\s*:\s*dark"#
    private static let colorSchemeDarkPattern = #"color-scheme\s*:[^;"'}]*\bdark\b"#
    private static let colorDeclarationPattern = #"(?:^|;)\s*color\s*:"#
    private static let backgroundDeclarationPattern = #"(?:^|;)\s*background(?:-color)?\s*:"#

    /// How many levels below `<body>` a colour declaration still counts as the message's own
    /// scheme rather than one styled link or span deep inside it.
    static let rootColorScanDepth = 2

    public static func pickCanvas(html: String?, theme: MVCanvas) -> MVCanvas {
        guard let html, !html.isEmpty, theme == .dark else { return theme }
        if declaresDarkModeSupport(html) { return .dark }
        return isDarkSafeMessage(html) ? .dark : .light
    }

    static func declaresDarkModeSupport(_ html: String) -> Bool {
        matches(darkModeMediaPattern, in: html) || matches(colorSchemeDarkPattern, in: html)
    }

    /// Safe on either canvas only when every root-level declaration sets `color` and
    /// `background` together — a shadow root isolates rules but not inheritance, so a template
    /// setting only one of the pair gets the other from the host. No declaration at all is
    /// judged unsafe: there is no evidence either way.
    static func isDarkSafeMessage(_ html: String) -> Bool {
        guard let document = try? SwiftSoup.parseBodyFragment(html), let body = document.body() else {
            return false
        }
        var declarations: [(color: Bool, background: Bool)] = []
        collectRootColorDeclarations(body, depth: 0, into: &declarations)
        guard !declarations.isEmpty else { return false }
        return declarations.allSatisfy { $0.color == $0.background }
    }

    private static func collectRootColorDeclarations(
        _ element: Element, depth: Int, into declarations: inout [(color: Bool, background: Bool)]
    ) {
        guard depth <= rootColorScanDepth else { return }
        if let style = try? element.attr("style"), !style.isEmpty {
            let hasColor = matches(colorDeclarationPattern, in: style)
            let hasBackground = matches(backgroundDeclarationPattern, in: style)
            if hasColor || hasBackground {
                declarations.append((hasColor, hasBackground))
            }
        }
        for child in element.children() {
            collectRootColorDeclarations(child, depth: depth + 1, into: &declarations)
        }
    }

    private static func matches(_ pattern: String, in text: String) -> Bool {
        text.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil
    }
}
