import Foundation

/// The on-disk copy of an order a ticket needs where there is no reception: its detail and the
/// PNG of every code. Written whenever an order is read from the server, and ahead of time for the
/// tickets coming up, so a code that has to be shown at a gate does not depend on the gate's network.
enum OrderOfflineCopy {
    /// How many upcoming tickets are kept ready without being opened first.
    static let upcomingLimit = 12

    /// True when the saved detail is the server's current version and every code image is saved.
    static func isCurrent(_ item: OrderListItem, in cache: MVOfflineCache) async -> Bool {
        guard let saved = await cache.order(id: item.id), saved.detail.updatedAt == item.updatedAt else {
            return false
        }
        for fact in saved.detail.codeFacts where await cache.orderCode(factId: fact.id) == nil {
            return false
        }
        return true
    }

    /// Saves the detail first (it is useful without its images), then each code image not saved yet.
    static func save(_ detail: OrderDetail, api: MVApiClient, in cache: MVOfflineCache) async {
        await cache.saveOrder(detail)
        for fact in detail.codeFacts {
            guard let code = fact.code, await cache.orderCode(factId: fact.id) == nil,
                let png = try? await api.getOrderCodeImage(code: code)
            else { continue }
            await cache.saveOrderCode(png, factId: fact.id)
        }
    }

    /// The tickets to keep ready: today's and later, the nearest first.
    static func upcoming(in items: [OrderListItem], today: String) -> [OrderListItem] {
        let tickets = items.filter { $0.kind == .ticket && ($0.timelineDay ?? "") >= today }
        return Array(tickets.sorted { ($0.timelineDay ?? "") < ($1.timelineDay ?? "") }.prefix(upcomingLimit))
    }

    static func prepare(
        _ items: [OrderListItem], today: String, api: MVApiClient, cache: MVOfflineCache
    ) async {
        for item in upcoming(in: items, today: today) {
            if Task.isCancelled { return }
            if await isCurrent(item, in: cache) { continue }
            guard let detail = try? await api.getOrder(id: item.id) else { continue }
            await save(detail, api: api, in: cache)
        }
    }
}
