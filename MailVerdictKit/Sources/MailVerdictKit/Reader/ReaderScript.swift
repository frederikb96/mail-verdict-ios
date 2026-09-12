import Foundation

/// `reader.js` — the page script the reader injects into its client content world — and the
/// names the app calls on it.
public enum ReaderScript {

    /// Every function `reader.js` exposes on `window.mvReader`.
    public enum Function: String, Sendable, CaseIterable {
        case fit
        case find
        case highlight
        case clearFind
        case replaceBlock
        case messageOffsets
        case openMessageIds
        case scrollToAnchor
    }

    public static let globalName = "mvReader"

    public static let source: String = {
        guard let url = Bundle.module.url(forResource: "reader", withExtension: "js"),
            let text = try? String(contentsOf: url, encoding: .utf8)
        else { return "" }
        return text
    }()

    /// A function body for `callAsyncJavaScript`, passing the named arguments through in order —
    /// the values travel as real arguments, never spliced into source.
    public static func call(_ function: Function, arguments: [String] = []) -> String {
        "return window.\(globalName).\(function.rawValue)(\(arguments.joined(separator: ", ")));"
    }
}
