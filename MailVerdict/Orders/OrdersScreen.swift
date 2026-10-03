import MailVerdictKit
import SwiftUI

/// The orders & tickets list — every purchase, ticket or booking bundle across every enabled
/// account, newest activity first.
struct OrdersScreen: View {
    let environment: AppEnvironment
    let connection: AppEnvironment.Connection

    @State private var store: OrderListStore
    @State private var isFirstRowVisible = true
    @State private var searchText = ""
    @State private var pendingDelete: OrderListItem?

    init(environment: AppEnvironment, connection: AppEnvironment.Connection) {
        self.environment = environment
        self.connection = connection
        let freshStore = OrderListStore(apiClient: connection.apiClient)
        self._store = State(initialValue: freshStore)
        #if DEBUG
            OrdersFixtures.activeListStore = freshStore
        #endif
    }

    var body: some View {
        content
            .navigationTitle("Orders & Tickets")
            .accessibilityIdentifier("orders-screen")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        ForEach(OrderListStore.Filter.allCases) { filter in
                            Button {
                                Task { await store.setFilter(filter) }
                            } label: {
                                if store.filter == filter {
                                    Label(filter.label, systemImage: "checkmark")
                                } else {
                                    Text(filter.label)
                                }
                            }
                        }
                    } label: {
                        Image(systemName: MVSymbols.filterUnread)
                    }
                }
            }
            .searchable(text: $searchText, prompt: "Filter orders")
            .onChange(of: searchText) { _, text in store.setQuery(text) }
            .deleteOrderAlert(order: $pendingDelete) { item in run(.delete, on: item) }
            .task {
                store.subscribeToLive(connection.liveEventHub)
                await store.load()
            }
            .onDisappear { store.unsubscribeFromLive(connection.liveEventHub) }
            #if DEBUG
                .screenshotReady(route: .orders, environment: environment, connection: connection)
            #endif
    }

    @ViewBuilder
    private var content: some View {
        if store.isLoading && store.rows.isEmpty {
            ProgressView()
        } else if let errorMessage = store.errorMessage {
            ErrorStateView(message: errorMessage) { Task { await store.load() } }
        } else if store.rows.isEmpty {
            EmptyStateView(systemImage: MVSymbols.orders, message: emptyMessage)
        } else {
            List {
                ForEach(store.rows) { item in
                    NavigationLink(value: Route.order(item.id)) {
                        OrderRow(item: item)
                    }
                    .swipeActions(edge: .leading, allowsFullSwipe: true) {
                        swipeButton(.close, for: item).tint(.blue)
                    }
                    .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                        swipeButton(.favorite, for: item).tint(.yellow)
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
    }

    private var emptyMessage: String {
        if !store.query.isEmpty { return "No matching orders" }
        return store.filter == .favorites ? "No favorites yet" : "No orders yet"
    }

    private func swipeButton(_ action: OrderAction, for item: OrderListItem) -> some View {
        let entry = OrderActionSet.entries(for: item.flags).first { $0.action == action }
        return Button {
            perform(action, on: item)
        } label: {
            Label(entry?.title ?? "", systemImage: entry?.systemImage ?? "questionmark")
        }
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
        isFirstRowVisible = atTop
        store.isAtTop = atTop
        if atTop, !store.held.isEmpty {
            withAnimation { store.takeOverHeld() }
        }
    }
}

private struct OrderRow: View {
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
                    Text("\(item.mailCount) mail\(item.mailCount == 1 ? "" : "s")")
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
}
