import Foundation
import Observation

/// One order's detail -- summary, identifiers, mails in time order, documents -- plus the three
/// corrections (rewrite, delete, detach a mail). `ReaderListSource` so a mail row opens the reader
/// paging through the order's own openable mails, oldest to newest.
@Observable
@MainActor
public final class OrderDetailStore {
    public let orderId: UUID
    public private(set) var order: OrderDetail?
    public private(set) var isLoading = false
    public private(set) var errorMessage: String?
    /// Set once the order is confirmed gone -- a 404 on load, a live `"deleted"` event, or this
    /// store's own `delete()`/`detachMail(...)` emptying it. The screen reads this to show "This
    /// order no longer exists" and clear the selection, per the design's own detail state table.
    public private(set) var wasDeleted = false

    private let apiClient: MVApiClient
    private var liveSubscriptionToken: MVSubscriptionToken?

    public init(orderId: UUID, apiClient: MVApiClient) {
        self.orderId = orderId
        self.apiClient = apiClient
    }

    public func load() async {
        isLoading = order == nil
        errorMessage = nil
        do {
            order = try await apiClient.getOrder(id: orderId)
        } catch let error as MVError where Self.isNotFound(error) {
            wasDeleted = true
        } catch {
            errorMessage = error.mvUserMessage
        }
        isLoading = false
    }

    /// Enqueues a manual rewrite -- `order.textStale` (refreshed on the next `load()`, or the
    /// live `order.updated` this causes) is what tells the screen a new summary is on its way.
    public func rewrite() async throws {
        try await apiClient.rewriteOrder(id: orderId)
    }

    public func delete() async throws {
        try await apiClient.deleteOrder(id: orderId)
        wasDeleted = true
    }

    /// Removes a mail from the order, optionally moving it to another. `nil` on the wire means
    /// the removal emptied the order and it was deleted -- reflected here as `wasDeleted`.
    public func detachMail(_ mail: OrderMailOut, moveTo: UUID? = nil) async throws {
        if let detail = try await apiClient.detachOrderMail(orderId: orderId, mailKey: mail.key, moveTo: moveTo) {
            order = detail
        } else {
            wasDeleted = true
        }
    }

    private static func isNotFound(_ error: MVError) -> Bool {
        switch error {
        case .detail(_, let statusCode), .http(let statusCode, _): return statusCode == 404
        case .transport, .decoding, .proxyRequiresBrowserLogin: return false
        }
    }
}

extension OrderDetailStore: ReaderListSource {
    /// Only the mails the reader can actually open -- a `"gone"` mail carries no `messageId` and
    /// stays in the order as a dimmed, unopenable snapshot instead.
    public var rowIds: [UUID] { order?.mails.compactMap(\.messageId) ?? [] }
    public var hasOlder: Bool { false }
    public var hasNewer: Bool { false }

    public func loadOlder() async {}
    public func loadNewer() async {}

    public var readerTitle: String? {
        guard let order else { return nil }
        return "\(order.mailCount) Mail\(order.mailCount == 1 ? "" : "s")"
    }
}

extension OrderDetailStore {
    public func subscribeToLive(_ hub: LiveEventHub) {
        guard liveSubscriptionToken == nil else { return }
        liveSubscriptionToken = hub.subscribe(self)
    }

    public func unsubscribeFromLive(_ hub: LiveEventHub) {
        guard let token = liveSubscriptionToken else { return }
        hub.unsubscribe(token)
        liveSubscriptionToken = nil
    }
}

extension OrderDetailStore: LiveEventSubscriber {
    public func apply(_ invalidations: [MVLiveInvalidation]) {
        for invalidation in invalidations {
            switch invalidation {
            case .resync:
                Task { await self.load() }
                return
            case .orderChanged(let id, let change) where id == nil || id == orderId:
                if change == "deleted" {
                    wasDeleted = true
                } else {
                    Task { await self.load() }
                }
                return
            default:
                continue
            }
        }
    }
}
