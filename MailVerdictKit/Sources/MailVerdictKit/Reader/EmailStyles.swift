import Foundation

/// The stylesheet injected into every message body's shadow root — `getEmailStyles` in
/// `email-renderer.tsx`, whose comments explain each rule. Differences from the web are only
/// where the reader works without page script: the quote toggle is a `<details>` summary
/// (`QuoteCollapser`), and find paints through the Custom Highlight API (`reader.js`), with the
/// web's `<mark>` classes kept for the fallback path.
public enum EmailStyles {

    public static func css(for canvas: MVCanvas) -> String {
        let isDark = canvas == .dark
        return """
            :host {
              display: block;
              contain: layout paint;
              font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, sans-serif;
              font-size: 14px;
              line-height: 1.6;
              word-wrap: break-word;
              overflow-wrap: break-word;
              color: \(isDark ? "#e4e4e7" : "#18181b");
              background: \(isDark ? "#09090b" : "#ffffff");
            }
            img {
              max-width: 100%;
              max-height: 70vh;
              height: auto;
              object-fit: contain;
            }
            a {
              color: \(isDark ? "#60a5fa" : "#2563eb");
            }
            table {
              max-width: 100%;
              border-collapse: collapse;
            }
            td, th {
              padding: 4px 8px;
            }
            blockquote {
              border-left: 3px solid \(isDark ? "#3f3f46" : "#d4d4d8");
              margin: 0.5em 0;
              padding: 0.25em 1em;
              color: \(isDark ? "#a1a1aa" : "#71717a");
            }
            pre {
              background: \(isDark ? "#18181b" : "#f4f4f5");
              padding: 8px 12px;
              border-radius: 4px;
              overflow-x: auto;
              font-size: 13px;
            }
            hr {
              border: none;
              border-top: 1px solid \(isDark ? "#27272a" : "#e4e4e7");
              margin: 1em 0;
            }
            details.mv-quote > summary {
              list-style: none;
              display: inline-flex;
              align-items: center;
              justify-content: center;
              min-width: 2.75em;
              padding: 0.2em 0.9em;
              border-radius: 999px;
              font-size: 0.8rem;
              letter-spacing: 0.05em;
              background: \(isDark ? "#3f3f46" : "#e4e4e7");
              color: \(isDark ? "#e4e4e7" : "#3f3f46");
              margin: 0.4em 0;
            }
            details.mv-quote > summary::-webkit-details-marker { display: none; }
            details.mv-quote[open] .mv-quote-show,
            details.mv-quote:not([open]) .mv-quote-hide { display: none; }
            .mv-sr-only {
              position: absolute;
              width: 1px;
              height: 1px;
              overflow: hidden;
              clip: rect(0, 0, 0, 0);
              white-space: nowrap;
            }
            ::highlight(mv-find), mark.search-match {
              background-color: \(isDark ? "#78350f" : "#fef08a");
              color: inherit;
            }
            ::highlight(mv-find-active), mark.search-match-active {
              background-color: #f97316;
              color: #1c1917;
            }
            """
    }
}
