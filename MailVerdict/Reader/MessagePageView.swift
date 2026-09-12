import MailVerdictKit
import UIKit
import WebKit

@MainActor
protocol MessagePageViewDelegate: AnyObject {
    func pageZoomWillBegin(_ page: MessagePageView)
    func pageZoomDidChange(_ page: MessagePageView)
    /// A drag on a zoomed page carried on past the edge it was pinned to; `edge == nil` means the
    /// drag came back and the pager returns to rest.
    func page(_ page: MessagePageView, handoffMoved distance: CGFloat, edge: MVZoomEdgeHandoff.Edge?)
    func page(
        _ page: MessagePageView, handoffEndedAt distance: CGFloat, edge: MVZoomEdgeHandoff.Edge, velocity: CGFloat,
        completed: Bool)
    func page(_ page: MessagePageView, didRequest navigation: MVReaderNavigation)
    func page(_ page: MessagePageView, menuFor link: MVReaderLink) -> UIMenu?
    func pageDidFinishLoading(_ page: MessagePageView)
}

/// One reader page: a `WKWebView` showing one conversation document, zoomed by WebKit's own pinch
/// (crisp text, the Safari zoom). The page reports zoom so the pager can stand still while it is
/// zoomed, and tracks a zoomed drag that runs past the content's edge for the Photos-style hand-off.
@MainActor
final class MessagePageView: UIView, WKNavigationDelegate, WKUIDelegate, UIScrollViewDelegate,
    UIFindInteractionDelegate
{
    let webView: WKWebView
    weak var delegate: MessagePageViewDelegate?

    /// The row this page shows; `nil` while it shows the "more rows loading" placeholder.
    private(set) var rowId: UUID?
    private(set) var isLoaded = false

    private var revealsOpened = false
    private var anchorToRestore: ReaderScrollAnchor?
    private var imagesAllowed = false
    private var loadGeneration = 0
    private var pinnedEdges: Set<MVZoomEdgeHandoff.Edge> = []
    private var handoff: (edge: MVZoomEdgeHandoff.Edge, distance: CGFloat)?

    private lazy var searcher = ReaderTextSearcher(page: self)
    private lazy var findInteraction = UIFindInteraction(sessionDelegate: self)

    init(configuration: WKWebViewConfiguration) {
        webView = WKWebView(frame: .zero, configuration: configuration)
        super.init(frame: .zero)
        backgroundColor = .systemBackground
        webView.isOpaque = false
        webView.backgroundColor = .systemBackground
        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.allowsLinkPreview = true

        let scrollView = webView.scrollView
        scrollView.delegate = self
        scrollView.isDirectionalLockEnabled = true
        scrollView.contentInsetAdjustmentBehavior = .never
        scrollView.panGestureRecognizer.addTarget(self, action: #selector(handleContentPan(_:)))
        // Backstop for the zoom callbacks: WebKit keeps its own scroll view delegate and
        // forwards to this one, and the pinch's own end is observed as well.
        scrollView.pinchGestureRecognizer?.addTarget(self, action: #selector(handlePinch(_:)))

        addSubview(webView)
        addInteraction(findInteraction)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("not used")
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        webView.frame = bounds
    }

    var zoomScale: CGFloat { webView.scrollView.zoomScale }
    var isZoomed: Bool { MVZoomEdgeHandoff.isZoomed(Double(zoomScale)) }
    var findResultCount: Int { searcher.resultCount }

    /// The bars float over the page; the document scrolls under them.
    func setContentInsets(top: CGFloat, bottom: CGFloat) {
        let insets = UIEdgeInsets(top: top, left: 0, bottom: bottom, right: 0)
        let scrollView = webView.scrollView
        guard scrollView.contentInset != insets else { return }
        scrollView.contentInset = insets
        scrollView.verticalScrollIndicatorInsets = insets
    }

    // MARK: Documents

    func show(rowId: UUID?, html: String, revealsOpened: Bool, imagesAllowed: Bool) {
        self.rowId = rowId
        load(html, revealsOpened: revealsOpened, imagesAllowed: imagesAllowed)
    }

    func apply(
        _ update: ReaderPageUpdate, imagesAllowed allowed: Bool,
        rebuild makeDocument: @escaping @MainActor ([String]) -> String
    ) {
        switch update {
        case .document(let html, let reveals):
            load(html, revealsOpened: reveals, imagesAllowed: allowed)
        case .rebuild:
            rebuild(imagesAllowed: allowed, makeDocument)
        case .replaceBlock(let id, let html):
            // A block that now shows remote images needs the other rule list, which only a
            // fresh load installs.
            if allowed != imagesAllowed {
                rebuild(imagesAllowed: allowed, makeDocument)
            } else {
                Task { try? await call(.replaceBlock, ["id": id, "html": html]) }
            }
        }
    }

    private func load(_ html: String, revealsOpened: Bool, imagesAllowed allowed: Bool) {
        loadGeneration += 1
        let generation = loadGeneration
        isLoaded = false
        self.revealsOpened = revealsOpened
        anchorToRestore = nil
        imagesAllowed = allowed
        dismissFind()
        ReaderWebKit.applyContentRules(to: webView.configuration.userContentController, imagesAllowed: allowed) {
            [weak self] in
            guard let self, generation == self.loadGeneration else { return }
            self.webView.loadHTMLString(html, baseURL: nil)
        }
    }

    /// Notes the reading position and the expanded messages, loads the rebuilt document, and puts
    /// the position back once it has laid out.
    private func rebuild(imagesAllowed allowed: Bool, _ makeDocument: @escaping @MainActor ([String]) -> String) {
        Task {
            let open = (try? await call(.openMessageIds)) as? [String] ?? []
            let anchor = await captureAnchor()
            load(makeDocument(open), revealsOpened: false, imagesAllowed: allowed)
            anchorToRestore = anchor
        }
    }

    func resetZoom(animated: Bool) {
        let scrollView = webView.scrollView
        guard scrollView.zoomScale != scrollView.minimumZoomScale else { return }
        scrollView.setZoomScale(scrollView.minimumZoomScale, animated: animated)
    }

    // MARK: Script

    @discardableResult
    private func call(_ function: ReaderScript.Function, _ arguments: KeyValuePairs<String, Any> = [:]) async throws
        -> Any?
    {
        let values = Dictionary(uniqueKeysWithValues: arguments.map { ($0.key, $0.value) })
        return try await webView.callAsyncJavaScript(
            ReaderScript.call(function, arguments: arguments.map(\.key)), arguments: values, in: nil,
            contentWorld: .defaultClient)
    }

    func find(_ query: String) async -> Int {
        ((try? await call(.find, ["query": query])) as? NSNumber)?.intValue ?? 0
    }

    func highlight(_ index: Int) async {
        _ = try? await call(.highlight, ["index": index])
    }

    func clearFind() async {
        _ = try? await call(.clearFind)
    }

    func presentFind() {
        findInteraction.presentFindNavigator(showingReplace: false)
    }

    func dismissFind() {
        if findInteraction.isFindNavigatorVisible {
            findInteraction.dismissFindNavigator()
        }
    }

    func findInteraction(_ interaction: UIFindInteraction, sessionFor view: UIView) -> UIFindSession? {
        UITextSearchingFindSession(searchableObject: searcher)
    }

    private func messagePositions() async -> [(id: String, top: Double)] {
        guard let rows = (try? await call(.messageOffsets)) as? [[String: Any]] else { return [] }
        return rows.compactMap { row in
            guard let id = row["id"] as? String, let top = (row["top"] as? NSNumber)?.doubleValue else { return nil }
            return (id, top)
        }
    }

    private var visibleTop: Double {
        Double(webView.scrollView.contentOffset.y + webView.scrollView.adjustedContentInset.top)
    }

    private func captureAnchor() async -> ReaderScrollAnchor? {
        ReaderScrollAnchor.capture(
            positions: await messagePositions(), visibleTop: visibleTop, zoomScale: Double(zoomScale))
    }

    private func scroll(toVisibleTop top: Double) {
        let scrollView = webView.scrollView
        let inset = scrollView.adjustedContentInset
        let maxY = max(-inset.top, scrollView.contentSize.height - scrollView.bounds.height + inset.bottom)
        let y = min(max(CGFloat(top) - inset.top, -inset.top), maxY)
        scrollView.setContentOffset(CGPoint(x: scrollView.contentOffset.x, y: y), animated: false)
    }

    /// Opening a message inside a longer conversation lands on it; the collapsed rows above have
    /// a fixed height, so the landing stays put.
    private func revealOpenedMessage() async {
        guard let rowId else { return }
        let positions = await messagePositions()
        let id = ConversationDocumentBuilder.messageElementId(rowId)
        guard let index = positions.firstIndex(where: { $0.id == id }), index > 0 else { return }
        scroll(toVisibleTop: positions[index].top * Double(zoomScale))
    }

    // MARK: WKNavigationDelegate

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction) async
        -> WKNavigationActionPolicy
    {
        guard let url = navigationAction.request.url else { return .cancel }
        let decision = MVReaderNavigation.classify(url, isUserAction: navigationAction.navigationType == .linkActivated)
        switch decision {
        case .allow:
            return .allow
        case .anchor(let name):
            _ = try? await call(.scrollToAnchor, ["name": name])
        case .ignore:
            break
        case .control, .web, .mailto:
            delegate?.page(self, didRequest: decision)
        }
        return .cancel
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        let generation = loadGeneration
        Task {
            guard generation == loadGeneration else { return }
            if let anchor = anchorToRestore {
                anchorToRestore = nil
                if let top = anchor.restoredVisibleTop(
                    positions: await messagePositions(), zoomScale: Double(zoomScale))
                {
                    scroll(toVisibleTop: top)
                }
            } else if revealsOpened {
                await revealOpenedMessage()
            }
            isLoaded = true
            delegate?.pageDidFinishLoading(self)
        }
    }

    // MARK: WKUIDelegate

    /// A web link keeps WebKit's own preview, which shows the URL; an attachment offers Quick
    /// Look and Share; the chrome's other controls get no menu.
    func webView(_ webView: WKWebView, contextMenuConfigurationFor elementInfo: WKContextMenuElementInfo) async
        -> UIContextMenuConfiguration?
    {
        guard let url = elementInfo.linkURL, let link = MVReaderLink(url: url) else { return nil }
        let menu = delegate?.page(self, menuFor: link)
        return UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { _ in menu }
    }

    // MARK: Zoom and the zoomed-edge hand-off

    func scrollViewWillBeginZooming(_ scrollView: UIScrollView, with view: UIView?) {
        delegate?.pageZoomWillBegin(self)
    }

    func scrollViewDidZoom(_ scrollView: UIScrollView) {
        delegate?.pageZoomDidChange(self)
    }

    func scrollViewDidEndZooming(_ scrollView: UIScrollView, with view: UIView?, atScale scale: CGFloat) {
        delegate?.pageZoomDidChange(self)
    }

    /// While the pager follows a hand-off, the content stays pinned at its edge instead of
    /// rubber-banding under the finger.
    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        guard let handoff else { return }
        let bounds = horizontalBounds(scrollView)
        let x = handoff.edge == .leading ? bounds.min : bounds.max
        if scrollView.contentOffset.x != x {
            scrollView.contentOffset.x = x
        }
    }

    @objc private func handlePinch(_ pinch: UIPinchGestureRecognizer) {
        switch pinch.state {
        case .began:
            delegate?.pageZoomWillBegin(self)
        case .ended, .cancelled, .failed:
            // The rubber band settles after the fingers lift.
            Task {
                try? await Task.sleep(nanoseconds: 400_000_000)
                delegate?.pageZoomDidChange(self)
            }
        default:
            break
        }
    }

    @objc private func handleContentPan(_ pan: UIPanGestureRecognizer) {
        let scrollView = webView.scrollView
        switch pan.state {
        case .began:
            let bounds = horizontalBounds(scrollView)
            pinnedEdges = MVZoomEdgeHandoff.pinnedEdges(
                zoomScale: Double(scrollView.zoomScale), offsetX: Double(scrollView.contentOffset.x),
                minOffsetX: Double(bounds.min), maxOffsetX: Double(bounds.max))
            handoff = nil
        case .changed:
            guard !pinnedEdges.isEmpty else { return }
            // In window coordinates: the page itself moves while the pager follows.
            let translation = pan.translation(in: nil)
            if let found = MVZoomEdgeHandoff.handoff(
                pinned: pinnedEdges, translationX: Double(translation.x), translationY: Double(translation.y))
            {
                handoff = (found.edge, CGFloat(found.distance))
                delegate?.page(self, handoffMoved: CGFloat(found.distance), edge: found.edge)
            } else if handoff != nil {
                handoff = nil
                delegate?.page(self, handoffMoved: 0, edge: nil)
            }
        case .ended, .cancelled, .failed:
            if let handoff {
                delegate?.page(
                    self, handoffEndedAt: handoff.distance, edge: handoff.edge, velocity: pan.velocity(in: nil).x,
                    completed: pan.state == .ended)
            }
            handoff = nil
            pinnedEdges = []
        default:
            break
        }
    }

    private func horizontalBounds(_ scrollView: UIScrollView) -> (min: CGFloat, max: CGFloat) {
        let inset = scrollView.adjustedContentInset
        let minX = -inset.left
        return (minX, max(minX, scrollView.contentSize.width - scrollView.bounds.width + inset.right))
    }

    #if DEBUG
        var debugContentWidth: Double { Double(webView.scrollView.contentSize.width) }
        var debugBoundsWidth: Double { Double(webView.scrollView.bounds.width) }
    #endif
}
