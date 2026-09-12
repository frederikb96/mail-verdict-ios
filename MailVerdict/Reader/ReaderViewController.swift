import MailVerdictKit
import Observation
import SafariServices
import UIKit

/// The pager's scroll view. Its pan is refused outright while the current page is zoomed, so a
/// zoomed page's drags always pan the message.
final class ReaderPagerView: UIScrollView {
    var allowsPaging: () -> Bool = { true }

    override func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        if gestureRecognizer === panGestureRecognizer, !allowsPaging() { return false }
        return super.gestureRecognizerShouldBegin(gestureRecognizer)
    }
}

/// Photos' paging structure: a paging `UIScrollView` holding the previous, current and next
/// page, recycled as the pager settles. Pages sit on a stride of width plus a 20 pt gap, the pager
/// widened by half a gap on each side, so the gap scrolls with the pages.
///
/// Left is the newer message (the row above in the list), right the older one — a swipe to the
/// left moves on through the list. The pager holds identities only, never list indices, so rows
/// arriving or leaving above the current one never move it.
@MainActor
final class ReaderViewController: UIViewController, UIScrollViewDelegate, MessagePageViewDelegate {
    private let model: ReaderScreenModel
    private let pager = ReaderPagerView()
    private var pageViews: [MessagePageView] = []

    private enum Slot: Equatable {
        case message(UUID)
        case loadingMore
    }

    private var slots: [Slot] = []
    private var slotPages: [MessagePageView] = []
    private var currentIndex = 0

    private enum Turn {
        case settle(resettingZoomOf: MessagePageView?)
        case returnToRest
    }

    private var turnInFlight: Turn?
    /// The user swiped onto the "more rows loading" page; it moves on once they arrive.
    private var waitingForMore: MVAutoAdvanceDirection?
    private var savedContentPopEnabled: Bool?
    private var requiresEdgePopToFail = false

    private static let gap: CGFloat = 20

    private var session: ReaderSession { model.session }
    private var paging: ReaderPagingStore { model.session.paging }
    private var stride: CGFloat { view.bounds.width + Self.gap }
    private var currentPage: MessagePageView? {
        slotPages.indices.contains(currentIndex) ? slotPages[currentIndex] : nil
    }

    init(model: ReaderScreenModel) {
        self.model = model
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("not used")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground

        pager.isPagingEnabled = true
        pager.showsHorizontalScrollIndicator = false
        pager.showsVerticalScrollIndicator = false
        pager.alwaysBounceHorizontal = true
        pager.isDirectionalLockEnabled = true
        pager.contentInsetAdjustmentBehavior = .never
        pager.scrollsToTop = false
        pager.delegate = self
        // A two-finger pinch must never start a page drag.
        pager.panGestureRecognizer.maximumNumberOfTouches = 1
        pager.allowsPaging = { [weak self] in !(self?.currentPage?.isZoomed ?? false) }
        view.addSubview(pager)

        pageViews = (0..<3).map { _ in
            let page = MessagePageView(configuration: ReaderWebKit.makeConfiguration(api: session.api))
            page.delegate = self
            pager.addSubview(page)
            return page
        }

        session.onPageUpdate = { [weak self] rowId, update in
            self?.apply(update, to: rowId)
        }
        observePaging()
        rebindSlots()
        session.didSettle(on: paging.currentId)
        #if DEBUG
            ReaderDebugHook.active = self
        #endif
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        layoutPages()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        guard let navigation = navigationController else { return }
        // The iOS 26 content pop recognizes a rightward pan anywhere — exactly "back to the newer
        // message". Off while the reader is visible; the edge swipe still goes back.
        if let contentPop = navigation.interactiveContentPopGestureRecognizer {
            if savedContentPopEnabled == nil { savedContentPopEnabled = contentPop.isEnabled }
            contentPop.isEnabled = false
        }
        if !requiresEdgePopToFail, let edgePop = navigation.interactivePopGestureRecognizer {
            pager.panGestureRecognizer.require(toFail: edgePop)
            requiresEdgePopToFail = true
        }
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        if let saved = savedContentPopEnabled {
            navigationController?.interactiveContentPopGestureRecognizer?.isEnabled = saved
            savedContentPopEnabled = nil
        }
    }

    // MARK: Slots

    private func slot(_ readerSlot: ReaderSlot) -> Slot {
        switch readerSlot {
        case .message(let id): return .message(id)
        case .loadingMore: return .loadingMore
        }
    }

    /// Lays the pages out for the store's current position, reusing the page already showing a
    /// row wherever it has moved to, so settling never reloads a web view.
    private func rebindSlots() {
        guard turnInFlight == nil else { return }
        var desired: [Slot] = []
        if let newer = paging.newer { desired.append(slot(newer)) }
        desired.append(.message(paging.currentId))
        let current = desired.count - 1
        if let older = paging.older { desired.append(slot(older)) }

        var available = pageViews
        var assigned = [MessagePageView?](repeating: nil, count: desired.count)
        for (index, slot) in desired.enumerated() {
            if case .message(let id) = slot, let match = available.firstIndex(where: { $0.rowId == id }) {
                assigned[index] = available.remove(at: match)
            }
        }
        for index in assigned.indices where assigned[index] == nil {
            assigned[index] = available.removeFirst()
        }
        for page in available {
            page.isHidden = true
            page.dismissFind()
        }

        slots = desired
        slotPages = assigned.compactMap { $0 }
        currentIndex = current
        for (page, slot) in zip(slotPages, slots) {
            page.isHidden = false
            bind(page, to: slot)
        }
        layoutPages()
        updatePagingEnabled()
    }

    private func bind(_ page: MessagePageView, to slot: Slot) {
        switch slot {
        case .message(let id):
            guard page.rowId != id else { return }
            let document = session.document(for: id)
            page.show(
                rowId: id, html: document.html, revealsOpened: document.revealsOpened,
                imagesAllowed: session.imagesAllowed(for: id))
        case .loadingMore:
            page.show(
                rowId: nil, html: ConversationDocumentBuilder.loadingDocument(theme: session.theme),
                revealsOpened: false,
                imagesAllowed: false)
        }
    }

    private func layoutPages() {
        guard view.bounds.width > 0 else { return }
        let size = view.bounds.size
        pager.frame = view.bounds.insetBy(dx: -Self.gap / 2, dy: 0)
        pager.contentSize = CGSize(width: CGFloat(slots.count) * stride, height: size.height)
        for (index, page) in slotPages.enumerated() {
            page.frame = CGRect(x: CGFloat(index) * stride + Self.gap / 2, y: 0, width: size.width, height: size.height)
            page.setContentInsets(top: view.safeAreaInsets.top, bottom: view.safeAreaInsets.bottom)
        }
        // Re-laid out by slot index, never derived from the old offset — a rotation lands on the
        // same page.
        if !pager.isDragging, !pager.isDecelerating, turnInFlight == nil {
            UIView.performWithoutAnimation {
                pager.contentOffset = CGPoint(x: CGFloat(currentIndex) * stride, y: 0)
            }
        }
    }

    private func updatePagingEnabled() {
        pager.isScrollEnabled = !(currentPage?.isZoomed ?? false)
    }

    private func apply(_ update: ReaderPageUpdate, to rowId: UUID) {
        guard let page = pageViews.first(where: { $0.rowId == rowId }) else { return }
        page.apply(update, imagesAllowed: session.imagesAllowed(for: rowId)) { [weak self] expanded in
            self?.session.rebuiltDocument(for: rowId, expandedElementIds: expanded) ?? ""
        }
    }

    private func observePaging() {
        withObservationTracking {
            _ = paging.currentId
            _ = paging.older
            _ = paging.newer
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                self?.pagingDidChange()
                self?.observePaging()
            }
        }
    }

    private func pagingDidChange() {
        guard turnInFlight == nil, !pager.isDragging, !pager.isDecelerating else { return }
        if let direction = waitingForMore, case .message? = (direction == .older ? paging.older : paging.newer) {
            waitingForMore = nil
            paging.move(direction)
            settled()
            return
        }
        rebindSlots()
    }

    // MARK: Settling and turning

    private func settled() {
        for page in pageViews where page !== currentPage { page.dismissFind() }
        rebindSlots()
        session.didSettle(on: paging.currentId)
    }

    private func neighbourIndex(_ direction: MVAutoAdvanceDirection) -> Int? {
        let index = direction == .older ? currentIndex + 1 : currentIndex - 1
        return slots.indices.contains(index) ? index : nil
    }

    /// The chevrons: they work even while zoomed, unzooming the page they leave.
    func turn(_ direction: MVAutoAdvanceDirection) {
        guard turnInFlight == nil, let target = neighbourIndex(direction), case .message = slots[target] else { return }
        currentPage?.resetZoom(animated: false)
        paging.move(direction)
        animate(to: target, then: .settle(resettingZoomOf: nil))
    }

    /// The store has already moved (an archive, a message that vanished): slide to the page now
    /// current, which sat on that side.
    func slideToCurrent(from direction: MVAutoAdvanceDirection) {
        guard let target = neighbourIndex(direction) else {
            settled()
            return
        }
        animate(to: target, then: .settle(resettingZoomOf: nil))
    }

    private func animate(to index: Int, then turn: Turn) {
        turnInFlight = turn
        let x = CGFloat(index) * stride
        if abs(pager.contentOffset.x - x) < 0.5 {
            finishTurn()
        } else {
            pager.setContentOffset(CGPoint(x: x, y: 0), animated: true)
        }
    }

    private func finishTurn() {
        guard let turn = turnInFlight else { return }
        turnInFlight = nil
        switch turn {
        case .settle(let outgoing):
            outgoing?.resetZoom(animated: false)
            settled()
        case .returnToRest:
            updatePagingEnabled()
        }
    }

    // MARK: UIScrollViewDelegate

    func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) {
        userDidSettle()
    }

    func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
        if !decelerate { userDidSettle() }
    }

    func scrollViewDidEndScrollingAnimation(_ scrollView: UIScrollView) {
        finishTurn()
    }

    private func userDidSettle() {
        guard stride > 0 else { return }
        let index = Int((pager.contentOffset.x / stride).rounded())
        guard index != currentIndex, slots.indices.contains(index) else { return }
        let direction: MVAutoAdvanceDirection = index < currentIndex ? .newer : .older
        switch slots[index] {
        case .message:
            currentPage?.resetZoom(animated: false)
            paging.move(direction)
            settled()
        case .loadingMore:
            waitingForMore = direction
        }
    }

    // MARK: MessagePageViewDelegate

    func pageZoomWillBegin(_ page: MessagePageView) {
        if page === currentPage { pager.isScrollEnabled = false }
    }

    func pageZoomDidChange(_ page: MessagePageView) {
        if page === currentPage { updatePagingEnabled() }
    }

    func page(_ page: MessagePageView, handoffMoved distance: CGFloat, edge: MVZoomEdgeHandoff.Edge?) {
        guard page === currentPage, turnInFlight == nil else { return }
        let rest = CGFloat(currentIndex) * stride
        guard let edge else {
            pager.contentOffset.x = rest
            return
        }
        let direction = MVZoomEdgeHandoff.direction(for: edge)
        // Past the end of the list the pager only gives a little, like a bounce.
        let travel = neighbourIndex(direction) != nil ? min(distance, stride) : distance * 0.3
        pager.contentOffset.x = direction == .newer ? rest - travel : rest + travel
    }

    func page(
        _ page: MessagePageView, handoffEndedAt distance: CGFloat, edge: MVZoomEdgeHandoff.Edge, velocity: CGFloat,
        completed: Bool
    ) {
        guard page === currentPage, turnInFlight == nil else { return }
        let direction = MVZoomEdgeHandoff.direction(for: edge)
        if completed, let target = neighbourIndex(direction), case .message = slots[target],
            MVZoomEdgeHandoff.shouldCommit(
                distance: Double(distance), velocityX: Double(velocity), edge: edge,
                pageWidth: Double(view.bounds.width))
        {
            paging.move(direction)
            animate(to: target, then: .settle(resettingZoomOf: page))
        } else {
            animate(to: currentIndex, then: .returnToRest)
        }
    }

    func page(_ page: MessagePageView, didRequest navigation: MVReaderNavigation) {
        model.handle(navigation)
    }

    func page(_ page: MessagePageView, menuFor link: MVReaderLink) -> UIMenu? {
        guard case .attachment(let messageId, let attachmentId) = link else { return nil }
        return UIMenu(children: [
            UIAction(title: "Quick Look", image: UIImage(systemName: "eye")) { [weak self] _ in
                self?.model.openAttachment(messageId: messageId, attachmentId: attachmentId)
            },
            UIAction(title: "Share…", image: UIImage(systemName: MVSymbols.shareMessageFile)) { [weak self] _ in
                self?.model.shareAttachment(messageId: messageId, attachmentId: attachmentId)
            },
        ])
    }

    func pageDidFinishLoading(_ page: MessagePageView) {
        if page === currentPage { updatePagingEnabled() }
    }

    // MARK: Presentations

    func presentFind() {
        currentPage?.presentFind()
    }

    func presentSafari(_ url: URL) {
        present(SFSafariViewController(url: url), animated: true)
    }

    func presentShare(_ url: URL) {
        let controller = UIActivityViewController(activityItems: [url], applicationActivities: nil)
        controller.popoverPresentationController?.sourceView = view
        present(controller, animated: true)
    }

    #if DEBUG
        var isCurrentPageLoaded: Bool {
            (currentPage?.isLoaded ?? false) && session.conversation(for: paging.currentId) != nil
        }

        /// Whether the current page has actually put a frame on screen — `isCurrentPageLoaded`
        /// only answers "navigation finished," which is well before a freshly spawned WebContent
        /// process paints anything.
        func currentPagePainted() async -> Bool {
            await currentPage?.debugIsPainted() ?? false
        }

        /// Whether the current page's document actually shows an invitation card.
        func showsInvitationCard() async -> Bool {
            await currentPage?.debugContains(".mv-invite") ?? false
        }

        var currentZoomScale: CGFloat { currentPage?.zoomScale ?? 1 }

        func zoomCurrentPage(to scale: CGFloat) {
            currentPage?.webView.scrollView.setZoomScale(scale, animated: false)
            updatePagingEnabled()
        }

        func showOptionsPreview() {
            model.optionsPreview = true
        }

        func debugState() -> ReaderDebugState {
            ReaderDebugState(
                currentId: paging.currentId.uuidString, olderId: paging.olderId?.uuidString,
                newerId: paging.newerId?.uuidString, title: session.title,
                zoomScale: Double(currentPage?.zoomScale ?? 1), pagerScrollEnabled: pager.isScrollEnabled,
                findResultCount: currentPage?.findResultCount ?? 0, pageLoaded: isCurrentPageLoaded,
                contentWidth: currentPage?.debugContentWidth ?? 0, boundsWidth: currentPage?.debugBoundsWidth ?? 0)
        }
    #endif
}
