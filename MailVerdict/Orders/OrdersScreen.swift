import MailVerdictKit
import SwiftUI

/// The orders & tickets list — every purchase, ticket or booking bundle across every enabled
/// account, newest activity first.
struct OrdersScreen: View {
    let environment: AppEnvironment
    let connection: AppEnvironment.Connection

    @State private var store: OrderListStore
    @State private var isFirstRowVisible = true

    init(environment: AppEnvironment, connection: AppEnvironment.Connection) {
        self.environment = environment
        self.connection = connection
        self._store = State(initialValue: OrderListStore(apiClient: connection.apiClient))
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
            .task {
                #if DEBUG
                    OrdersFixtures.activeListStore = store
                #endif
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
            EmptyStateView(systemImage: MVSymbols.orders, message: "No orders yet")
        } else {
            List {
                ForEach(store.rows) { item in
                    NavigationLink(value: Route.order(item.id)) {
                        OrderRow(item: item)
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
