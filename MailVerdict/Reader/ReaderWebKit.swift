import MailVerdictKit
import WebKit

/// The web view setup every reader page shares: no page script, no persistent website data, the
/// reader's own script in the app's client world, the scheme handlers that fetch attachments and
/// sender photos with the app's credential, and the content rule lists that keep remote loads out.
@MainActor
enum ReaderWebKit {
    static let dataStore = WKWebsiteDataStore.nonPersistent()

    private static var compiled: [String: WKContentRuleList] = [:]
    private static var isCompiling = false
    private static var waiting: [@MainActor () -> Void] = []
    private static var ready = false

    static func makeConfiguration(api: MVApiClient) -> WKWebViewConfiguration {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = dataStore
        // Message markup never runs script; the reader's own script runs in the client world.
        configuration.defaultWebpagePreferences.allowsContentJavaScript = false
        let handler = ReaderSchemeHandler(api: api)
        configuration.setURLSchemeHandler(handler, forURLScheme: MessageBodyRenderer.attachmentScheme)
        configuration.setURLSchemeHandler(handler, forURLScheme: ReaderPhotoURL.scheme)
        let controller = WKUserContentController()
        controller.addUserScript(
            WKUserScript(
                source: ReaderScript.source, injectionTime: .atDocumentEnd, forMainFrameOnly: true, in: .defaultClient))
        configuration.userContentController = controller
        configuration.dataDetectorTypes = []
        return configuration
    }

    /// Installs the strict rule list, or the one that lets images through, then runs `load`. The
    /// lists compile once per launch; a page asking before that waits for them.
    static func applyContentRules(
        to controller: WKUserContentController, imagesAllowed: Bool, then load: @escaping @MainActor () -> Void
    ) {
        whenReady {
            controller.removeAllContentRuleLists()
            let identifier =
                imagesAllowed ? ReaderContentRules.imagesAllowedIdentifier : ReaderContentRules.strictIdentifier
            if let list = compiled[identifier] {
                controller.add(list)
            }
            load()
        }
    }

    private static func whenReady(_ body: @escaping @MainActor () -> Void) {
        if ready {
            body()
            return
        }
        waiting.append(body)
        guard !isCompiling, let store = WKContentRuleListStore.default() else { return }
        isCompiling = true
        let lists = [
            (ReaderContentRules.strictIdentifier, ReaderContentRules.strict),
            (ReaderContentRules.imagesAllowedIdentifier, ReaderContentRules.imagesAllowed),
        ]
        compile(lists, in: store)
    }

    private static func compile(_ remaining: [(String, String)], in store: WKContentRuleListStore) {
        guard let (identifier, json) = remaining.first else {
            ready = true
            isCompiling = false
            let pending = waiting
            waiting = []
            pending.forEach { $0() }
            return
        }
        store.compileContentRuleList(forIdentifier: identifier, encodedContentRuleList: json) { list, error in
            if let list {
                compiled[identifier] = list
            } else if let error {
                DebugLog.error("content rule list \(identifier) failed to compile: \(error)")
            }
            compile(Array(remaining.dropFirst()), in: store)
        }
    }
}

/// Serves `mv-attachment://` and `mv-photo://` through the authenticated API client — a web view
/// cannot attach the app's credential to a subresource request itself.
@MainActor
final class ReaderSchemeHandler: NSObject, WKURLSchemeHandler {
    private let api: MVApiClient
    private var running: Set<ObjectIdentifier> = []

    init(api: MVApiClient) {
        self.api = api
    }

    func webView(_ webView: WKWebView, start urlSchemeTask: any WKURLSchemeTask) {
        guard let url = urlSchemeTask.request.url else {
            urlSchemeTask.didFailWithError(URLError(.badURL))
            return
        }
        let key = ObjectIdentifier(urlSchemeTask)
        running.insert(key)
        Task {
            let result = await load(url)
            // WebKit raises if a stopped task is answered.
            guard running.remove(key) != nil else { return }
            switch result {
            case .success(let (data, mimeType)):
                urlSchemeTask.didReceive(
                    URLResponse(url: url, mimeType: mimeType, expectedContentLength: data.count, textEncodingName: nil))
                urlSchemeTask.didReceive(data)
                urlSchemeTask.didFinish()
            case .failure(let error):
                urlSchemeTask.didFailWithError(error)
            }
        }
    }

    func webView(_ webView: WKWebView, stop urlSchemeTask: any WKURLSchemeTask) {
        running.remove(ObjectIdentifier(urlSchemeTask))
    }

    private func load(_ url: URL) async -> Result<(Data, String), Error> {
        do {
            if url.scheme?.lowercased() == MessageBodyRenderer.attachmentScheme,
                let messageId = url.host.flatMap(UUID.init(uuidString:)),
                let attachmentId = UUID(uuidString: url.lastPathComponent)
            {
                let result = try await api.getAttachment(messageId: messageId, attachmentId: attachmentId)
                return .success((result.data, Self.mimeType(result.contentType)))
            }
            if let contactId = ReaderPhotoURL.contactId(from: url) {
                let result = try await api.getContactPhoto(contactId: contactId)
                return .success((result.data, Self.mimeType(result.contentType)))
            }
            return .failure(URLError(.unsupportedURL))
        } catch {
            return .failure(error)
        }
    }

    private static func mimeType(_ contentType: String?) -> String {
        contentType?.split(separator: ";").first.map { $0.trimmingCharacters(in: .whitespaces) }
            ?? "application/octet-stream"
    }
}

/// Reader diagnostics in the debug bridge's log ring; a no-op in release builds.
enum DebugLog {
    static func error(_ message: String) {
        #if DEBUG
            DebugLogBuffer.shared.append(.error, "reader", message)
        #endif
    }
}
