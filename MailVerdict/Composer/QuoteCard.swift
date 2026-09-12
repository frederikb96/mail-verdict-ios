import MailVerdictKit
import SwiftUI
import WebKit

/// The quoted original under a reply or forward: atomic, never edited, collapsed behind "Show
/// quoted text" and removable as a whole — the web's quote node.
struct QuoteCard: View {
    let quote: ComposeQuote
    let onRemove: () -> Void

    @State private var expanded = false
    @State private var contentHeight: CGFloat = 80

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 8) {
                Text(quote.attribution)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Button(role: .destructive, action: onRemove) {
                    Image(systemName: "xmark.circle.fill")
                        .symbolRenderingMode(.hierarchical)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Remove Quoted Text")
            }
            Button(expanded ? "Hide quoted text" : "Show quoted text") {
                withAnimation { expanded.toggle() }
            }
            .font(.footnote.weight(.semibold))
            .accessibilityIdentifier("composer-quote-toggle")
            if expanded {
                QuoteWebView(html: quote.html, height: $contentHeight)
                    .frame(height: contentHeight)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
            }
        }
        .padding(12)
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12))
        .accessibilityIdentifier("composer-quote-card")
    }
}

/// A read-only, content-height web view rendering the quote on the light canvas quoted mail is
/// written for. No script runs, nothing persists, and a tapped link goes nowhere — this is a
/// preview of what will be sent, not a browser.
private struct QuoteWebView: UIViewRepresentable {
    let html: String
    @Binding var height: CGFloat

    func makeCoordinator() -> Coordinator { Coordinator(height: $height) }

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = false
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.scrollView.isScrollEnabled = false
        webView.isOpaque = false
        webView.navigationDelegate = context.coordinator
        webView.loadHTMLString(Self.document(for: html), baseURL: nil)
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {}

    private static func document(for body: String) -> String {
        """
        <!doctype html><html><head><meta name="viewport" content="width=device-width, initial-scale=1">
        <style>
        :root { color-scheme: light; }
        body { margin: 0; padding: 10px 12px; background: #fff; color: #111;
               font: -apple-system-body; font-size: 14px; overflow-wrap: anywhere; }
        img { max-width: 100%; height: auto; }
        table { max-width: 100%; }
        blockquote { margin: 0 0 0 .8ex; border-left: 1px solid #ccc; padding-left: 1ex; }
        pre { white-space: pre-wrap; }
        </style></head><body>\(body)</body></html>
        """
    }

    @MainActor
    final class Coordinator: NSObject, WKNavigationDelegate {
        let height: Binding<CGFloat>

        init(height: Binding<CGFloat>) {
            self.height = height
        }

        func webView(
            _ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction
        ) async -> WKNavigationActionPolicy {
            navigationAction.navigationType == .other ? .allow : .cancel
        }

        /// Measured again shortly after, because images finish loading after the document does.
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            measure(webView)
            Task { @MainActor [weak self, weak webView] in
                try? await Task.sleep(for: .milliseconds(400))
                if let webView { self?.measure(webView) }
            }
        }

        private func measure(_ webView: WKWebView) {
            let measured = max(webView.scrollView.contentSize.height, 40)
            if abs(measured - height.wrappedValue) > 1 { height.wrappedValue = measured }
        }
    }
}
