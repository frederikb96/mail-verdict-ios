import Foundation

/// Makes a message's own `prefers-color-scheme` rules answer to the canvas it is drawn on rather
/// than to the operating system — port of `alignColorSchemeQueries` in `email-renderer.tsx`.
///
/// The web rewrites each query through the browser's parsed stylesheet; message pages here run no
/// script, so `MessageMarkupWriter` applies the same rewrite to the text of each `<style>` block
/// and its `media` attribute as it writes the body. Only the colour-scheme feature is replaced,
/// with a media feature whose answer never changes while a message is on screen, so the rest of
/// the query keeps meaning what the sender wrote.
public enum ColorSchemeQueryAligner {

    static let alwaysMatchingFeature = "(min-width: 0px)"
    static let neverMatchingFeature = "(max-width: 0px)"

    private static let featureRegex = try! NSRegularExpression(
        pattern: #"\(\s*prefers-color-scheme\s*:\s*(dark|light)\s*\)"#, options: .caseInsensitive)

    public static func align(_ css: String, canvas: MVCanvas) -> String {
        let nsCSS = css as NSString
        let matches = featureRegex.matches(in: css, range: NSRange(location: 0, length: nsCSS.length))
        guard !matches.isEmpty else { return css }

        var result = ""
        var cursor = 0
        for match in matches {
            let scheme = nsCSS.substring(with: match.range(at: 1)).lowercased()
            result += nsCSS.substring(with: NSRange(location: cursor, length: match.range.location - cursor))
            result += scheme == canvas.rawValue ? alwaysMatchingFeature : neverMatchingFeature
            cursor = match.range.location + match.range.length
        }
        result += nsCSS.substring(from: cursor)
        return result
    }
}
