import MailVerdictKit
import SwiftUI

/// Tickets by the day they are for: what is still ahead above a "Today" marker, what has passed
/// below, opening with the marker in the middle of the screen.
///
/// Every row has one fixed height (scaled with Dynamic Type), so nothing above the reader is ever
/// measured late and the marker's position is exactly what it was laid out as. A jump to today is
/// held on the marker while the list settles and let go at the first touch of the reader; coming
/// back from an order is no jump, so the reader finds the list where it was.
struct OrderTimelineList: View {
    let store: OrderListStore
    let perform: (OrderAction, OrderListItem) -> Void

    @ScaledMetric(relativeTo: .body) private var rowHeight: CGFloat = 96
    @ScaledMetric(relativeTo: .body) private var markerHeight: CGFloat = 44
    /// True from a jump to today until the reader first touches the list.
    @State private var holdsToday = true
    @State private var centring: Task<Void, Never>?

    var body: some View {
        let timeline = store.timeline
        ScrollViewReader { proxy in
            List {
                ForEach(timeline.entries) { entry in
                    switch entry {
                    case .today:
                        TodayMarker()
                            .frame(height: markerHeight)
                            .listRowInsets(EdgeInsets(top: 0, leading: 16, bottom: 0, trailing: 16))
                            .listRowSeparator(.hidden)
                            .id(entry.id)
                            #if DEBUG
                                .onGeometryChange(for: CGRect.self) { proxy in
                                    proxy.frame(in: .global)
                                } action: { frame in
                                    OrdersDebugState.shared.markerFrame = frame
                                }
                                .onDisappear { OrdersDebugState.shared.markerFrame = nil }
                            #endif
                    case .order(let item):
                        NavigationLink(value: Route.order(item.id)) {
                            OrderTimelineRow(item: item)
                        }
                        .frame(height: rowHeight)
                        .id(entry.id)
                        .swipeActions(edge: .leading, allowsFullSwipe: true) {
                            OrderSwipeButton(action: .close, flags: item.flags) { perform(.close, item) }.tint(.blue)
                        }
                        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                            OrderSwipeButton(action: .favorite, flags: item.flags) { perform(.favorite, item) }
                                .tint(.yellow)
                        }
                        .contextMenu {
                            OrderActionMenuItems(flags: item.flags) { action in perform(action, item) }
                        }
                    }
                }
                if store.hasMore {
                    ProgressView()
                        .frame(maxWidth: .infinity)
                        .task { await store.loadMore() }
                }
            }
            .listStyle(.plain)
            .refreshable { await store.load() }
            .onScrollPhaseChange { _, phase in
                if phase == .interacting { holdsToday = false }
            }
            #if DEBUG
                .onGeometryChange(for: CGRect.self) { proxy in
                    proxy.frame(in: .global)
                } action: { frame in
                    OrdersDebugState.shared.viewportFrame = frame
                }
            #endif
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Today") { store.requestTodayJump() }
                        .accessibilityIdentifier("orders-today")
                }
            }
            .onChange(of: store.owesTodayJump, initial: true) { _, owed in
                guard owed else { return }
                store.todayJumpTaken()
                holdsToday = true
                centring?.cancel()
                centring = Task { await keepCentred(proxy) }
            }
            .onDisappear { centring?.cancel() }
        }
        #if DEBUG
            .onAppear { OrdersDebugState.shared.rowHeight = Double(rowHeight) }
            .onChange(of: timeline.todayIndex, initial: true) { _, index in
                OrdersDebugState.shared.todayIndex = index
            }
        #endif
    }

    /// Rows mounting after the first layout move the marker, so the centring is asserted again a
    /// few times as the list settles, and stops the moment the reader takes over.
    private func keepCentred(_ proxy: ScrollViewProxy) async {
        for delay in [0, 120, 300, 700] {
            if delay > 0 { try? await Task.sleep(for: .milliseconds(delay)) }
            guard holdsToday, !Task.isCancelled else { return }
            proxy.scrollTo(OrderTimeline.todayID, anchor: .center)
        }
    }
}

private struct TodayMarker: View {
    var body: some View {
        HStack(spacing: 10) {
            Rectangle().fill(Color.accentColor).frame(height: 1)
            Text("TODAY · \(MVDateFormat.eventDay(MVOrderDay.string(for: Date())))")
                .font(.caption.weight(.bold))
                .foregroundStyle(Color.accentColor)
                .fixedSize()
            Rectangle().fill(Color.accentColor).frame(height: 1)
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("orders-today-marker")
    }
}

/// One ticket on the timeline: its day, then who and what.
struct OrderTimelineRow: View {
    let item: OrderListItem

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(spacing: 0) {
                if let day = item.timelineDay, let date = MVOrderDay.date(from: day) {
                    Text(date.formatted(.dateTime.weekday(.abbreviated)).uppercased())
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Text(date.formatted(.dateTime.day()))
                        .font(.title2.weight(.semibold))
                        .monospacedDigit()
                    Text(date.formatted(.dateTime.month(.abbreviated)).uppercased())
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                } else {
                    Image(systemName: "calendar.badge.questionmark").foregroundStyle(.secondary)
                }
            }
            .frame(width: 44)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 4) {
                    Text(item.merchant.uppercased())
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    if item.isFavorite {
                        Image(systemName: MVSymbols.starFilled).font(.caption).foregroundStyle(.yellow)
                            .accessibilityLabel("Favorite")
                    }
                }
                Text(item.subject)
                    .font(.body.weight(.semibold))
                    .lineLimit(1)
                HStack(spacing: 4) {
                    if !item.status.isEmpty {
                        Chip(text: item.status.capitalized, tint: item.isOpen ? .blue : .secondary)
                    }
                    if let range = rangeText { Text(range).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
                }
            }
            Spacer(minLength: 0)
        }
        .frame(maxHeight: .infinity, alignment: .center)
    }

    /// Only a multi-day event says more than the day column does.
    private var rangeText: String? {
        guard let end = item.eventEnd, let start = item.eventStart, end != start else { return nil }
        return MVDateFormat.eventRange(start: start, end: end)
    }
}
