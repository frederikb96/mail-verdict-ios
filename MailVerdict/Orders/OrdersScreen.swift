import MailVerdictKit
import SwiftUI

/// The orders & tickets list. A one-tap kind control (All, Orders, Tickets) and the Open and
/// Favorites chips choose the view; Tickets open as a timeline centred on today with a Today button
/// to return to it, everything else is newest activity first.
struct OrdersScreen: View {
    let environment: AppEnvironment
    let connection: AppEnvironment.Connection

    @State private var store: OrderListStore
    @State private var searchText = ""
    @State private var pendingDelete: OrderListItem?
    @State private var isImportingFile = false
    @State private var isPickingPhoto = false

    init(environment: AppEnvironment, connection: AppEnvironment.Connection) {
        self.environment = environment
        self.connection = connection
        let freshStore = OrderListStore(
            apiClient: connection.apiClient, persistence: OrderViewPersistence(),
            offlineCache: connection.offlineCache)
        self._store = State(initialValue: freshStore)
    }

    var body: some View {
        content
            .navigationTitle("Orders & Tickets")
            .accessibilityIdentifier("orders-screen")
            .safeAreaInset(edge: .top, spacing: 0) { viewControls }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button {
                            isImportingFile = true
                        } label: {
                            Label("Add File…", systemImage: "doc.badge.plus")
                        }
                        Button {
                            isPickingPhoto = true
                        } label: {
                            Label("Add Photo…", systemImage: "photo.badge.plus")
                        }
                    } label: {
                        Image(systemName: "plus")
                    }
                    .accessibilityLabel("Add to orders")
                    .accessibilityIdentifier("orders-add")
                }
            }
            .searchable(text: $searchText, prompt: "Filter orders")
            .onChange(of: searchText) { _, text in store.setQuery(text) }
            .deleteOrderAlert(order: $pendingDelete) { item in run(.delete, on: item) }
            .orderFileImport(
                isImporting: $isImportingFile, isPickingPhoto: $isPickingPhoto, onPicked: { upload($0) },
                onFailure: { showUploadError($0) }
            )
            #if DEBUG
                // Ahead of the data-loading `.task` below, on purpose: a fixture-mode sweep's own
                // screenshot-readiness task registers this screen's routes, and it has to win the
                // race against this screen's own first load -- a load that gets there first is a
                // request no fixture route answered.
                .screenshotReady(route: .orders, environment: environment, connection: connection)
                .onChange(of: "\(store.view.identity) \(store.rows.count)", initial: true) {
                    OrdersDebugState.shared.record(view: store.view, rowCount: store.rows.count)
                }
            #endif
            .task {
                #if DEBUG
                    // The instance this screen keeps: `init` also runs for instances SwiftUI discards.
                    OrdersFixtures.activeListStore = store
                #endif
                store.subscribeToLive(connection.liveEventHub)
                await store.loadOrRefresh()
            }
            .onChange(of: environment.requestedOrderView, initial: true) { _, requested in
                guard let requested else { return }
                environment.requestedOrderView = nil
                store.requestTodayJump()
                Task { await store.setView(requested) }
            }
            .onDisappear { store.unsubscribeFromLive(connection.liveEventHub) }
    }

    // MARK: Controls

    private var viewControls: some View {
        VStack(spacing: 8) {
            Picker(
                "Kind",
                selection: Binding(
                    get: { store.view.kind }, set: { kind in Task { await store.setKind(kind) } })
            ) {
                ForEach(OrderKindFilter.allCases) { kind in Text(kind.label).tag(kind) }
            }
            .pickerStyle(.segmented)
            .accessibilityIdentifier("orders-kind-picker")
            HStack(spacing: 8) {
                FilterChip(title: "Open", systemImage: "circle.dashed", isOn: store.view.open) {
                    Task { await store.toggleOpen() }
                }
                .accessibilityIdentifier("orders-chip-open")
                FilterChip(title: "Favorites", systemImage: MVSymbols.starFilled, isOn: store.view.favorites) {
                    Task { await store.toggleFavorites() }
                }
                .accessibilityIdentifier("orders-chip-favorites")
                Spacer()
            }
            if let notice = MVOfflineNotice.make(reachability: connection.reachability, savedAt: store.savedCopyAt) {
                OfflineCapsule(notice: notice)
                    .accessibilityIdentifier("orders-offline")
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(.bar)
    }

    // MARK: Content

    @ViewBuilder
    private var content: some View {
        if store.isLoading && store.rows.isEmpty {
            ProgressView().frame(maxHeight: .infinity)
        } else if let errorMessage = store.errorMessage {
            ErrorStateView(message: errorMessage) { Task { await store.load() } }
        } else if store.rows.isEmpty {
            EmptyStateView(systemImage: MVSymbols.orders, message: emptyMessage)
        } else if store.view.isTimeline {
            OrderTimelineList(store: store, perform: { action, item in perform(action, on: item) })
        } else {
            activityList
        }
    }

    private var activityList: some View {
        List {
            ForEach(store.rows) { item in
                NavigationLink(value: Route.order(item.id)) {
                    OrderRow(item: item)
                }
                .swipeActions(edge: .leading, allowsFullSwipe: true) {
                    OrderSwipeButton(action: .close, flags: item.flags) { perform(.close, on: item) }.tint(.blue)
                }
                .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                    OrderSwipeButton(action: .favorite, flags: item.flags) { perform(.favorite, on: item) }
                        .tint(.yellow)
                }
                .contextMenu {
                    OrderActionMenuItems(flags: item.flags) { action in perform(action, on: item) }
                }
                .onAppear { if store.rows.first?.id == item.id { setAtTop(true) } }
                .onDisappear { if store.rows.first?.id == item.id { setAtTop(false) } }
            }
            if store.hasMore {
                ProgressView()
                    .frame(maxWidth: .infinity)
                    .task { await store.loadMore() }
            }
        }
        .id(store.view.identity)
        .listStyle(.plain)
        .refreshable { await store.load() }
        .overlay(alignment: .top) {
            if !store.held.isEmpty {
                Button("New activity") { withAnimation { store.takeOverHeld() } }
                    .buttonStyle(.borderedProminent)
                    .buttonBorderShape(.capsule)
                    .controlSize(.small)
                    .padding(.top, 8)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
    }

    private var emptyMessage: String {
        if !store.query.isEmpty { return "No matching orders" }
        let noun: String
        switch store.view.kind {
        case .all: noun = "orders"
        case .orders: noun = "orders"
        case .tickets: noun = "tickets"
        }
        if store.view.favorites { return "No favorite \(noun)" }
        return store.view.open ? "No open \(noun)" : "No \(noun) yet"
    }

    /// Delete asks first; everything else runs at once and confirms with a toast.
    private func perform(_ action: OrderAction, on item: OrderListItem) {
        if action == .delete {
            pendingDelete = item
        } else {
            run(action, on: item)
        }
    }

    private func run(_ action: OrderAction, on item: OrderListItem) {
        Task {
            do {
                if let message = try await store.perform(action, on: item) {
                    environment.toasts.show(.init(variant: .info, message: message, duration: 2.5))
                }
            } catch {
                environment.toasts.show(.init(variant: .error, message: "Could not update: \(error.mvUserMessage)"))
            }
        }
    }

    /// Reaching the top also takes over whatever is held, not only a tap on the pill itself.
    private func setAtTop(_ atTop: Bool) {
        store.isAtTop = atTop
        if atTop, !store.held.isEmpty {
            withAnimation { store.takeOverHeld() }
        }
    }

    // MARK: Adding a file with no order chosen

    /// The server reads the file and places it in the order it belongs to, or a new one; the list
    /// updates when the entry is written.
    private func upload(_ file: PickedOrderFile) {
        Task {
            do {
                let status = try await connection.apiClient.uploadOrderFile(
                    data: file.data, filename: file.filename, contentType: file.contentType)
                if status.isFailed {
                    showUploadError(MVError.detail(status.lastError ?? "The file could not be read.", statusCode: 422))
                } else {
                    environment.toasts.show(
                        .init(variant: .info, message: "Added \(file.filename). Analysing…", duration: 3))
                }
            } catch {
                showUploadError(error)
            }
        }
    }

    private func showUploadError(_ error: Error) {
        environment.toasts.show(.init(variant: .error, message: "Could not add the file: \(error.mvUserMessage)"))
    }
}

/// A row swipe: the wording and symbol come from `OrderActionSet`, so a swipe cannot disagree
/// with the menus.
struct OrderSwipeButton: View {
    let action: OrderAction
    let flags: OrderFlags
    let onTap: () -> Void

    var body: some View {
        let entry = OrderActionSet.entries(for: flags).first { $0.action == action }
        Button(action: onTap) {
            Label(entry?.title ?? "", systemImage: entry?.systemImage ?? "questionmark")
        }
    }
}

/// Open and Favorites: independent toggles that combine with the kind.
private struct FilterChip: View {
    let title: String
    let systemImage: String
    let isOn: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: isOn ? "checkmark" : systemImage)
                .font(.subheadline.weight(.medium))
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .foregroundStyle(isOn ? Color.white : Color.primary)
                .background(Capsule().fill(isOn ? Color.accentColor : Color.secondary.opacity(0.15)))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isOn ? .isSelected : [])
    }
}

struct OrderRow: View {
    let item: OrderListItem

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            RoundedRectangle(cornerRadius: 10)
                .fill(MVPalette.orderTint(item.icon).opacity(0.15))
                .frame(width: 40, height: 40)
                .overlay {
                    Image(systemName: MVSymbols.orderIcon(item.icon))
                        .font(.body.weight(.semibold))
                        .foregroundStyle(MVPalette.orderTint(item.icon))
                }
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text(item.merchant.uppercased())
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    if item.isFavorite {
                        Image(systemName: MVSymbols.starFilled)
                            .font(.caption)
                            .foregroundStyle(.yellow)
                            .accessibilityLabel("Favorite")
                    }
                    if item.isSealed {
                        Image(systemName: "lock.fill")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .accessibilityLabel("Sealed, takes no more mail")
                    }
                    Spacer()
                    Text(MVDateFormat.dateRange(item.firstMailAt, item.lastMailAt))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                Text(item.subject)
                    .font(.body.weight(.semibold))
                    .lineLimit(1)
                HStack(spacing: 4) {
                    if !item.status.isEmpty {
                        Chip(text: item.status.capitalized, tint: item.isOpen ? .blue : .secondary)
                    }
                    if item.kind == .ticket,
                        let day = MVDateFormat.eventRange(start: item.eventStart, end: item.eventEnd)
                    {
                        Chip(text: day, tint: .orange)
                    }
                    Text(countText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Text(item.summaryPreview)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
        .padding(.vertical, 6)
    }

    private var countText: String {
        var parts = ["\(item.mailCount) mail\(item.mailCount == 1 ? "" : "s")"]
        if item.fileCount > 0 { parts.append("\(item.fileCount) file\(item.fileCount == 1 ? "" : "s")") }
        return parts.joined(separator: " · ")
    }
}
