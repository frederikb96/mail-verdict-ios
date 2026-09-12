import MailVerdictKit
import SwiftUI
import UIKit

/// The list's scrolling surface: a plain `UITableView` with one fixed row height, measured from
/// the real row view at the current Dynamic Type size. Every row is the same height, so every
/// row's position is arithmetic — nothing is ever estimated, and a change above the reader is
/// corrected by exactly the rows it moved (`MVListAnchoring`).
///
/// The store owns the rows; this controller owns the viewport. Each change to the rows is
/// applied as one snapshot and the offset corrected in the same main-thread turn, before
/// anything is drawn. While another screen covers the list, changes queue and are applied when
/// it comes back, from the offset it was left at.
@MainActor
final class MailListViewController: UIViewController, UITableViewDelegate {

    struct Actions {
        /// A tap outside select mode.
        var open: (MessageSummary) -> Void
        /// A swipe or context-menu action. Returns after the store has made its optimistic
        /// change, so the table can reflect it before a swipe's completion runs.
        var perform: (MVMessageUIAction, MessageSummary) -> Void
        var showOptions: (MessageSummary) -> Void
        var openAccounts: () -> Void
    }

    private static let cellIdentifier = "MailRow"
    private static let pagingFooterHeight: CGFloat = 44

    private let store: MVMailListStore
    var actions: Actions

    private let tableView = UITableView(frame: .zero, style: .plain)
    private let pagingSpinner = UIActivityIndicatorView(style: .medium)
    private var dataSource: UITableViewDiffableDataSource<Int, UUID>?

    private var displayedRows: [UUID: MessageSummary] = [:]
    private var appliedRows: [MessageSummary] = []
    private var appliedIds: [UUID] = []
    private var appliedIdentity: MVListIdentity?
    private var appliedHasNewer = false
    /// Where the reader was in each list identity they left — only ever restored when that
    /// exact identity comes back (clearing the quick filter).
    private var anchorsByIdentity: [MVListIdentity: MVListAnchor] = [:]
    private var isOnScreen = false
    private var hasQueuedApply = false
    private var isApplying = false
    private var measuredSizeCategory: UIContentSizeCategory?
    private var bannerText: String?
    private var bannerHost: UIHostingController<DeadOutboxBanner>?
    private var isRequestingOlder = false
    private var isRequestingNewer = false

    init(store: MVMailListStore, actions: Actions) {
        self.store = store
        self.actions = actions
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground

        tableView.frame = view.bounds
        tableView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        tableView.delegate = self
        // No estimates anywhere: a row's height is the one measured value in `rowHeight`.
        tableView.estimatedRowHeight = 0
        tableView.estimatedSectionHeaderHeight = 0
        tableView.estimatedSectionFooterHeight = 0
        tableView.sectionHeaderTopPadding = 0
        tableView.allowsMultipleSelectionDuringEditing = true
        // Inset to the text: 4 leading + 12 unread column + 40 avatar + 12 gap.
        tableView.separatorInset = UIEdgeInsets(top: 0, left: 68, bottom: 0, right: 0)
        tableView.register(UITableViewCell.self, forCellReuseIdentifier: Self.cellIdentifier)
        tableView.tableFooterView = makePagingFooter()
        tableView.accessibilityIdentifier = "maillist-table"

        let refresh = UIRefreshControl()
        refresh.addTarget(self, action: #selector(pulledToRefresh), for: .valueChanged)
        tableView.refreshControl = refresh

        view.addSubview(tableView)
        dataSource = makeDataSource()

        NotificationCenter.default.addObserver(
            self, selector: #selector(appDidEnterBackground), name: UIApplication.didEnterBackgroundNotification,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self, selector: #selector(appDidBecomeActive), name: UIApplication.didBecomeActiveNotification, object: nil
        )
        observeStore()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        updateRowHeight()
        resizeBannerIfNeeded()
        if hasQueuedApply && (isOnScreen || appliedIdentity == nil) {
            applyFromStore()
        }
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        setContentPopGestureEnabled(false)
        isOnScreen = true
        updateRowHeight()
        if hasQueuedApply { applyFromStore() }
        revealLastViewedRow()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        // Asserted again once the transition has settled, whatever order the screen leaving
        // restored it in.
        setContentPopGestureEnabled(false)
        publishDebugState()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        savePosition()
        isOnScreen = false
        setContentPopGestureEnabled(true)
        publishDebugState()
    }

    /// iOS 26's content-pop gesture pops on a leading-to-trailing pan anywhere in the content —
    /// exactly the Archive swipe. Off while the list is up; the edge-swipe Back stays.
    private func setContentPopGestureEnabled(_ enabled: Bool) {
        navigationController?.interactiveContentPopGestureRecognizer?.isEnabled = enabled
    }

    func scrollToTop() {
        tableView.setContentOffset(CGPoint(x: 0, y: geometry().minOffsetY), animated: true)
        store.clearNewRowsAbove()
    }

    // MARK: - Store observation

    private func observeStore() {
        withObservationTracking {
            _ = store.rows
            _ = store.identity
            _ = store.hasNewer
            _ = store.hasOlder
            _ = store.pendingLanding
            _ = store.selection
            _ = store.isSelecting
            _ = store.isLoadingOlder
            _ = store.context
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.storeDidChange()
                self.observeStore()
            }
        }
    }

    private func storeDidChange() {
        if tableView.isEditing != store.isSelecting {
            tableView.setEditing(store.isSelecting, animated: true)
        }
        updateBanner()
        applyFromStore()
        reconcileSelection()
        updatePagingFooter()
    }

    // MARK: - Applying rows

    /// Applies the store's rows. A different list starts at the top (or where the reader left
    /// that exact list); the same list changed keeps the reader's row where it was — except at
    /// the very top of a window starting at the newest message, where new mail is shown.
    private func applyFromStore() {
        guard !isApplying, let dataSource else { return }
        guard isOnScreen || appliedIdentity == nil, measuredSizeCategory != nil, tableView.bounds.width > 0 else {
            hasQueuedApply = true
            return
        }
        hasQueuedApply = false
        isApplying = true
        defer { isApplying = false }

        var seen = Set<UUID>()
        let rows = store.rows.filter { seen.insert($0.id).inserted }
        let identity = store.identity
        guard identity != appliedIdentity || rows != appliedRows else {
            applyLanding()
            publishDebugState()
            return
        }

        let newIds = rows.map(\.id)
        let before = geometry()
        let offset = Double(tableView.contentOffset.y)
        var target: Double
        var arrivalsAbove = 0
        if identity != appliedIdentity {
            if let applied = appliedIdentity,
                let anchor = MVListAnchoring.anchor(offsetY: offset, geometry: before, rowIds: appliedIds)
            {
                anchorsByIdentity[applied] = anchor
            }
            target =
                anchorsByIdentity[identity].flatMap {
                    MVListAnchoring.offsetY(restoring: $0, rowIds: newIds, geometry: before)
                } ?? before.minOffsetY
        } else {
            target = MVListAnchoring.offsetAfterChange(
                offsetY: offset, oldIds: appliedIds, newIds: newIds, geometry: before,
                windowAtNewestEdge: !appliedHasNewer
            )
            if !appliedHasNewer && !MVListAnchoring.isAtTop(offsetY: offset, geometry: before) {
                arrivalsAbove = MVListAnchoring.newRowsAbove(
                    offsetY: offset, oldIds: appliedIds, newIds: newIds, geometry: before
                )
            }
        }

        var snapshot = NSDiffableDataSourceSnapshot<Int, UUID>()
        snapshot.appendSections([0])
        snapshot.appendItems(newIds, toSection: 0)
        let changed = rows.filter { row in displayedRows[row.id].map { $0 != row } ?? false }.map(\.id)
        if !changed.isEmpty { snapshot.reconfigureItems(changed) }

        displayedRows = Dictionary(rows.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        appliedRows = rows
        appliedIds = newIds
        appliedIdentity = identity
        appliedHasNewer = store.hasNewer

        UIView.performWithoutAnimation {
            dataSource.apply(snapshot, animatingDifferences: false)
            tableView.layoutIfNeeded()
            setOffset(target)
        }

        if arrivalsAbove > 0 { store.noteNewRowsAbove(arrivalsAbove) }
        applyLanding()
        reconcileSelection()
        checkPaging()
        publishDebugState()
    }

    /// A first page that opened around a message, or a relaunch restoring a saved position.
    private func applyLanding() {
        guard !appliedIds.isEmpty, let landing = store.consumeLanding() else { return }
        switch landing {
        case .restore(let anchor):
            if let offset = MVListAnchoring.offsetY(restoring: anchor, rowIds: appliedIds, geometry: geometry()) {
                setOffset(offset)
            }
        case .revealInUpperThird(let rowId):
            if let index = appliedIds.firstIndex(of: rowId) {
                setOffset(
                    MVListAnchoring.offsetPlacingInUpperThird(
                        rowIndex: index, geometry: geometry(), rowCount: appliedIds.count
                    )
                )
            }
        }
    }

    /// Back after paging the reader away from the opened row: the least scroll that shows the
    /// row the reader ended on, and nothing at all when it is already in view.
    private func revealLastViewedRow() {
        guard let rowId = store.lastViewedMessageId, rowId != store.openedMessageId,
            let index = appliedIds.firstIndex(of: rowId),
            let offset = MVListAnchoring.offsetRevealing(
                rowIndex: index, offsetY: Double(tableView.contentOffset.y), geometry: geometry(),
                rowCount: appliedIds.count
            )
        else { return }
        setOffset(offset)
    }

    private func setOffset(_ offsetY: Double) {
        let clamped = geometry().clamped(offsetY, rowCount: appliedIds.count)
        guard abs(Double(tableView.contentOffset.y) - clamped) > 0.01 else { return }
        tableView.contentOffset = CGPoint(x: tableView.contentOffset.x, y: CGFloat(clamped))
    }

    private func geometry() -> MVListGeometry {
        MVListGeometry(
            rowHeight: Double(max(tableView.rowHeight, 0)),
            firstRowY: Double(tableView.tableHeaderView?.frame.height ?? 0),
            trailingHeight: Double(tableView.tableFooterView?.frame.height ?? 0),
            topInset: Double(tableView.adjustedContentInset.top),
            bottomInset: Double(tableView.adjustedContentInset.bottom),
            viewportHeight: Double(tableView.bounds.height)
        )
    }

    private func currentAnchor() -> MVListAnchor? {
        MVListAnchoring.anchor(offsetY: Double(tableView.contentOffset.y), geometry: geometry(), rowIds: appliedIds)
    }

    private func isAtTop() -> Bool {
        MVListAnchoring.isAtTop(offsetY: Double(tableView.contentOffset.y), geometry: geometry())
    }

    private func savePosition() {
        guard !appliedIds.isEmpty else { return }
        store.savePosition(anchor: currentAnchor(), atTop: isAtTop())
    }

    // MARK: - Row height

    /// Measured once per Dynamic Type size from the real row view filled on every line it
    /// reserves, then the reader's row restored.
    private func updateRowHeight() {
        let category = traitCollection.preferredContentSizeCategory
        guard view.bounds.width > 0, category != measuredSizeCategory else { return }
        let anchor = currentAnchor()
        measuredSizeCategory = category
        let height = measureRowHeight(width: view.bounds.width)
        guard height != tableView.rowHeight else { return }
        tableView.rowHeight = height
        guard let dataSource, !appliedIds.isEmpty else { return }
        dataSource.applySnapshotUsingReloadData(dataSource.snapshot())
        tableView.layoutIfNeeded()
        if let anchor, let offset = MVListAnchoring.offsetY(restoring: anchor, rowIds: appliedIds, geometry: geometry())
        {
            setOffset(offset)
        }
    }

    private func measureRowHeight(width: CGFloat) -> CGFloat {
        let dynamicType = DynamicTypeSize(traitCollection.preferredContentSizeCategory) ?? .large
        let host = UIHostingController(
            rootView: MailListRowContent(data: .measurementSample).environment(\.dynamicTypeSize, dynamicType)
        )
        let size = host.sizeThatFits(in: CGSize(width: width, height: .greatestFiniteMagnitude))
        let scale = max(traitCollection.displayScale, 1)
        return max((size.height * scale).rounded(.up) / scale, 44)
    }

    // MARK: - Cells

    private func makeDataSource() -> UITableViewDiffableDataSource<Int, UUID> {
        let source = UITableViewDiffableDataSource<Int, UUID>(tableView: tableView) {
            [weak self] tableView, indexPath, rowId in
            MainActor.assumeIsolated {
                let cell = tableView.dequeueReusableCell(
                    withIdentifier: MailListViewController.cellIdentifier, for: indexPath
                )
                guard let self, let row = self.displayedRows[rowId] else { return cell }
                self.configure(cell, with: row)
                return cell
            }
        }
        source.defaultRowAnimation = .fade
        return source
    }

    private func configure(_ cell: UITableViewCell, with row: MessageSummary) {
        let data = store.rowData(for: row)
        cell.contentConfiguration = UIHostingConfiguration {
            MailListRowContent(data: data)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .margins(.all, 0)
        cell.accessibilityIdentifier = "maillist-row-\(row.id.uuidString)"
    }

    private func row(at indexPath: IndexPath) -> MessageSummary? {
        dataSource?.itemIdentifier(for: indexPath).flatMap { displayedRows[$0] }
    }

    private func run(_ action: MVMessageUIAction, on row: MessageSummary) {
        actions.perform(action, row)
        applyFromStore()
    }

    // MARK: - Selection

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        guard let row = row(at: indexPath) else { return }
        if tableView.isEditing {
            store.toggleSelection(of: row.id)
            return
        }
        tableView.deselectRow(at: indexPath, animated: true)
        store.didOpen(row.id)
        actions.open(row)
    }

    func tableView(_ tableView: UITableView, didDeselectRowAt indexPath: IndexPath) {
        guard tableView.isEditing, let row = row(at: indexPath) else { return }
        store.toggleSelection(of: row.id)
    }

    /// A two-finger pan down the rows enters select mode and ticks as it goes.
    func tableView(_ tableView: UITableView, shouldBeginMultipleSelectionInteractionAt indexPath: IndexPath) -> Bool {
        true
    }

    func tableView(_ tableView: UITableView, didBeginMultipleSelectionInteractionAt indexPath: IndexPath) {
        store.setSelecting(true)
        tableView.setEditing(true, animated: true)
    }

    func tableView(_ tableView: UITableView, willDisplay cell: UITableViewCell, forRowAt indexPath: IndexPath) {
        if tableView.isEditing { syncSelection(at: indexPath) }
    }

    /// The table's own selection follows the store's — under select-all every matching row
    /// shows ticked without ever having been tapped.
    private func reconcileSelection() {
        guard tableView.isEditing else { return }
        for indexPath in tableView.indexPathsForVisibleRows ?? [] { syncSelection(at: indexPath) }
    }

    private func syncSelection(at indexPath: IndexPath) {
        guard let rowId = dataSource?.itemIdentifier(for: indexPath) else { return }
        let shouldBeSelected = store.isSelected(rowId)
        let isSelected = tableView.indexPathsForSelectedRows?.contains(indexPath) ?? false
        if shouldBeSelected && !isSelected {
            tableView.selectRow(at: indexPath, animated: false, scrollPosition: .none)
        } else if !shouldBeSelected && isSelected {
            tableView.deselectRow(at: indexPath, animated: false)
        }
    }

    // MARK: - Swipes

    /// Swipe right: Archive, the only action, performed by a full swipe.
    func tableView(
        _ tableView: UITableView, leadingSwipeActionsConfigurationForRowAt indexPath: IndexPath
    ) -> UISwipeActionsConfiguration? {
        guard !tableView.isEditing, let row = row(at: indexPath) else { return nil }
        let archive = UIContextualAction(style: .normal, title: MVMessageUIAction.archive.title) {
            [weak self] _, _, completion in
            MainActor.assumeIsolated { self?.run(.archive, on: row) }
            completion(true)
        }
        archive.image = UIImage(systemName: MVSymbols.archive)
        archive.backgroundColor = .systemBlue
        let configuration = UISwipeActionsConfiguration(actions: [archive])
        configuration.performsFirstActionWithFullSwipe = true
        return configuration
    }

    /// Swipe left: Delete first, so a full swipe deletes; a short swipe shows Options and Delete.
    /// In Trash, Delete is Delete Forever and asks first — the row stays until confirmed.
    func tableView(
        _ tableView: UITableView, trailingSwipeActionsConfigurationForRowAt indexPath: IndexPath
    ) -> UISwipeActionsConfiguration? {
        guard !tableView.isEditing, let row = row(at: indexPath) else { return nil }
        let deleteAction: MVMessageUIAction = store.isInTrash(row) ? .deleteForever : .delete
        let delete = UIContextualAction(style: .destructive, title: deleteAction.title) {
            [weak self] _, _, completion in
            MainActor.assumeIsolated { self?.run(deleteAction, on: row) }
            completion(deleteAction == .delete)
        }
        delete.image = UIImage(systemName: deleteAction.symbol)
        let options = UIContextualAction(style: .normal, title: "Options") { [weak self] _, _, completion in
            MainActor.assumeIsolated { self?.actions.showOptions(row) }
            completion(true)
        }
        options.image = UIImage(systemName: MVSymbols.options)
        options.backgroundColor = .systemGray
        let configuration = UISwipeActionsConfiguration(actions: [delete, options])
        configuration.performsFirstActionWithFullSwipe = true
        return configuration
    }

    // MARK: - Context menu

    func tableView(
        _ tableView: UITableView, contextMenuConfigurationForRowAt indexPath: IndexPath, point: CGPoint
    ) -> UIContextMenuConfiguration? {
        guard !tableView.isEditing, let row = row(at: indexPath) else { return nil }
        let preview = MailContextPreview(
            data: store.rowData(for: row), fullDate: MVDateFormat.fullDate(row.receivedAt), snippet: row.snippet
        )
        let menu = makeMenu(for: row)
        return UIContextMenuConfiguration(
            identifier: row.id.uuidString as NSString,
            previewProvider: {
                MainActor.assumeIsolated {
                    let host = UIHostingController(rootView: preview)
                    host.preferredContentSize = host.sizeThatFits(in: CGSize(width: 340, height: 420))
                    return host
                }
            },
            actionProvider: { _ in menu }
        )
    }

    /// The same groups as the swipe's Options sheet, as inline menu sections; Respond and the
    /// verdict pair show as a compact row, the way Mail shows Reply/Forward.
    private func makeMenu(for row: MessageSummary) -> UIMenu {
        let groups = MessageActionSet.actions(for: store.actionContext(for: row, surface: .contextMenu))
        let sections: [UIMenuElement] = groups.map { group in
            let items = group.actions.map { action in
                UIAction(
                    title: action.title, image: UIImage(systemName: action.symbol),
                    attributes: action.isDestructive ? [.destructive] : []
                ) { [weak self] _ in
                    MainActor.assumeIsolated { self?.run(action, on: row) }
                }
            }
            let title =
                group.kind == .verdict
                ? (row.verdictIsSpam == true ? "Classified as spam" : "Classified as not spam") : ""
            let compact = group.kind == .respond || group.kind == .verdict
            return UIMenu(
                title: title, options: .displayInline, preferredElementSize: compact ? .medium : .automatic,
                children: items
            )
        }
        return UIMenu(children: sections)
    }

    // MARK: - Scrolling and paging

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        guard !isApplying else { return }
        checkPaging()
        if isAtTop() { store.clearNewRowsAbove() }
        publishDebugState()
    }

    func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) {
        savePosition()
    }

    func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
        if !decelerate { savePosition() }
    }

    func scrollViewDidScrollToTop(_ scrollView: UIScrollView) {
        store.clearNewRowsAbove()
        savePosition()
    }

    /// Pages load within two screens of either end, well before the reader gets there.
    private func checkPaging() {
        guard !appliedIds.isEmpty, tableView.rowHeight > 0 else { return }
        let needs = MVListAnchoring.pagingNeeds(
            offsetY: Double(tableView.contentOffset.y), geometry: geometry(), rowCount: appliedIds.count
        )
        if needs.older && store.hasOlder && !isRequestingOlder {
            isRequestingOlder = true
            Task { [weak self] in
                await self?.store.loadOlder()
                self?.isRequestingOlder = false
                self?.checkPaging()
            }
        }
        if needs.newer && store.hasNewer && !isRequestingNewer {
            isRequestingNewer = true
            Task { [weak self] in
                await self?.store.loadNewer()
                self?.isRequestingNewer = false
                self?.checkPaging()
            }
        }
    }

    private func makePagingFooter() -> UIView {
        let footer = UIView(frame: CGRect(x: 0, y: 0, width: 0, height: Self.pagingFooterHeight))
        pagingSpinner.translatesAutoresizingMaskIntoConstraints = false
        pagingSpinner.hidesWhenStopped = true
        footer.addSubview(pagingSpinner)
        NSLayoutConstraint.activate([
            pagingSpinner.centerXAnchor.constraint(equalTo: footer.centerXAnchor),
            pagingSpinner.centerYAnchor.constraint(equalTo: footer.centerYAnchor),
        ])
        return footer
    }

    private func updatePagingFooter() {
        if store.isLoadingOlder {
            pagingSpinner.startAnimating()
        } else {
            pagingSpinner.stopAnimating()
        }
    }

    @objc private func pulledToRefresh() {
        Task { [weak self] in
            await self?.store.pullToRefresh()
            self?.tableView.refreshControl?.endRefreshing()
        }
    }

    @objc private func appDidEnterBackground() {
        savePosition()
    }

    @objc private func appDidBecomeActive() {
        store.requestRefresh()
    }

    // MARK: - Banner

    /// The dead-outbox banner sits above the rows as the table's header. Its arrival or
    /// departure changes where every row sits, so the reader's row is restored across it —
    /// unless they are at the top, where the banner is shown.
    private func updateBanner() {
        let text = store.deadOutboxBanner
        guard text != bannerText else { return }
        bannerText = text
        let anchor = currentAnchor()
        let wasAtTop = isAtTop()
        if let bannerHost {
            bannerHost.willMove(toParent: nil)
            bannerHost.view.removeFromSuperview()
            bannerHost.removeFromParent()
            self.bannerHost = nil
        }
        if let text {
            let host = UIHostingController(
                rootView: DeadOutboxBanner(text: text) { [weak self] in self?.actions.openAccounts() }
            )
            host.view.backgroundColor = .clear
            addChild(host)
            bannerHost = host
            tableView.tableHeaderView = host.view
            host.didMove(toParent: self)
            sizeBanner()
        } else {
            tableView.tableHeaderView = nil
        }
        tableView.layoutIfNeeded()
        restore(anchor, wasAtTop: wasAtTop)
    }

    private func resizeBannerIfNeeded() {
        guard let header = tableView.tableHeaderView, abs(header.frame.width - tableView.bounds.width) > 0.5 else {
            return
        }
        let anchor = currentAnchor()
        let wasAtTop = isAtTop()
        sizeBanner()
        restore(anchor, wasAtTop: wasAtTop)
    }

    private func sizeBanner() {
        guard let bannerHost else { return }
        let width = tableView.bounds.width
        let height = bannerHost.sizeThatFits(in: CGSize(width: width, height: .greatestFiniteMagnitude)).height
        bannerHost.view.frame = CGRect(x: 0, y: 0, width: width, height: height)
        // A header's height is read when it is assigned.
        tableView.tableHeaderView = bannerHost.view
    }

    private func restore(_ anchor: MVListAnchor?, wasAtTop: Bool) {
        if wasAtTop {
            setOffset(geometry().minOffsetY)
        } else if let anchor,
            let offset = MVListAnchoring.offsetY(restoring: anchor, rowIds: appliedIds, geometry: geometry())
        {
            setOffset(offset)
        }
    }

    // MARK: - Debug bridge

    private func publishDebugState() {
        #if DEBUG
            let geometry = geometry()
            let offset = Double(tableView.contentOffset.y)
            let anchor = MVListAnchoring.anchor(offsetY: offset, geometry: geometry, rowIds: appliedIds)
            let identity = store.identity
            let selection = store.effectiveSelection
            MailListDebugState.shared.update(
                MailListDebugSnapshot(
                    listIdentity: "\(identity.scope) threaded=\(identity.threaded) unread=\(identity.unreadOnly) "
                        + "filter=\(identity.filterQuery) generation=\(identity.generation)",
                    firstVisibleRowId: anchor?.rowId.uuidString, offsetInRow: anchor?.offsetInRow,
                    contentOffsetY: offset, rowHeight: geometry.rowHeight, loadedCount: appliedIds.count,
                    hasOlder: store.hasOlder, hasNewer: store.hasNewer, newArrivalCount: store.newMessagesCapsuleCount,
                    isOnScreen: isOnScreen, isSelecting: store.isSelecting, selectionCount: selection.count,
                    selectionIsPredicate: selection.predicate != nil,
                    lastViewedMessageId: store.lastViewedMessageId?.uuidString, phase: "\(store.phase)"
                )
            )
        #endif
    }
}

/// The list's own margins around the shared `MailRowView` — one definition, used both to
/// measure the row height and to draw every row, so the two cannot disagree.
struct MailListRowContent: View {
    let data: MVMailRowData

    var body: some View {
        MailRowView(data: data)
            .padding(.leading, 4)
            .padding(.trailing, 16)
    }
}

extension MVMailRowData {
    /// Fills every line a row reserves — a pending-sync spinner, every mark, a snippet long
    /// enough to wrap onto both preview lines — so the row height measured from it is the most
    /// any row can need.
    static let measurementSample = MVMailRowData.plain(
        id: UUID(uuidString: "00000000-0000-0000-0000-0000000e0001") ?? UUID(), isUnread: true,
        senderName: "Measurement Sender", dateText: "Yesterday", pendingSync: true,
        subject: "A subject long enough to fill its line", threadCount: 12, isAnswered: true, hasAttachments: true,
        verdictIsSpam: true, isStarred: true,
        snippet: String(repeating: "A preview long enough to wrap onto both of its lines. ", count: 8),
        avatarIdentity: "measure@example.com"
    )
}

/// The long-press preview: the message's header and opening lines, natively — no web view.
struct MailContextPreview: View {
    let data: MVMailRowData
    let fullDate: String
    let snippet: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top, spacing: 12) {
                AvatarView(identity: data.avatarIdentity, displayName: data.senderName, photo: data.avatarPhoto)
                VStack(alignment: .leading, spacing: 2) {
                    Text(data.senderName).font(.headline).lineLimit(1)
                    Text(fullDate).font(.subheadline).foregroundStyle(.secondary)
                }
            }
            if let subject = data.subject {
                Text(subject).font(.subheadline.weight(.semibold)).lineLimit(2)
            }
            if let snippet {
                Text(snippet).font(.subheadline).foregroundStyle(.secondary).lineLimit(6)
            }
        }
        .padding(16)
        .frame(width: 340, alignment: .leading)
    }
}

/// "N messages could not be sent — check SMTP settings on …", above the rows; a tap opens Accounts.
struct DeadOutboxBanner: View {
    let text: String
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                Text(text).font(.subheadline).multilineTextAlignment(.leading)
                Spacer(minLength: 0)
            }
            .foregroundStyle(MVPalette.deadBannerText)
            .padding(12)
            .background(MVPalette.deadBannerBackground, in: RoundedRectangle(cornerRadius: 12))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .accessibilityIdentifier("maillist-dead-outbox-banner")
    }
}

/// Lets the SwiftUI screen reach the one thing only the controller can do.
@MainActor
final class MailListControllerProxy {
    weak var controller: MailListViewController?

    func scrollToTop() {
        controller?.scrollToTop()
    }
}

struct MailListTable: UIViewControllerRepresentable {
    let store: MVMailListStore
    let proxy: MailListControllerProxy
    let actions: MailListViewController.Actions

    func makeUIViewController(context: Context) -> MailListViewController {
        let controller = MailListViewController(store: store, actions: actions)
        proxy.controller = controller
        return controller
    }

    func updateUIViewController(_ controller: MailListViewController, context: Context) {
        controller.actions = actions
    }
}
