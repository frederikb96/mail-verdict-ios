import Foundation
import Observation

/// One order's detail -- summary, key facts, mails in time order, documents -- plus the
/// corrections (rewrite, delete, detach a mail, change its kind) and adding or removing a file.
/// `ReaderListSource` so a mail row opens the reader paging through the order's own openable mails,
/// oldest to newest. Every read from the server leaves an offline copy (the detail and its code
/// images) that stands in when the server cannot be reached.
@Observable
@MainActor
public final class OrderDetailStore {
    public let orderId: UUID
    public private(set) var order: OrderDetail?
    public private(set) var isLoading = false
    public private(set) var errorMessage: String?
    /// Set once the order is confirmed gone -- a 404 on load, a live `"deleted"` event, or this
    /// store's own `delete()`/`detachMail(...)` emptying it. The screen reads this to show "This
    /// order no longer exists" and clear the selection.
    public private(set) var wasDeleted = false
    /// When the order on screen was saved, if it came from the offline copy rather than the server.
    public private(set) var savedCopyAt: Date?
    /// The code fact shown fullscreen, if any. Presentation state lives here so what is on screen
    /// is one value that a screenshot entry and the screen read alike.
    public var presentedCodeFactId: UUID?
    /// Files being added, until each is part of the order or has failed.
    public private(set) var uploads: [OrderUpload] = []

    private let apiClient: MVApiClient
    private let offlineCache: MVOfflineCache?
    private let uploadPollInterval: Duration
    private let uploadPollLimit: Int
    private var liveSubscriptionToken: MVSubscriptionToken?

    public init(
        orderId: UUID, apiClient: MVApiClient, offlineCache: MVOfflineCache? = nil,
        uploadPollInterval: Duration = .seconds(2), uploadPollLimit: Int = 45
    ) {
        self.orderId = orderId
        self.apiClient = apiClient
        self.offlineCache = offlineCache
        self.uploadPollInterval = uploadPollInterval
        self.uploadPollLimit = uploadPollLimit
    }

    public func load() async {
        isLoading = order == nil
        errorMessage = nil
        do {
            let detail = try await apiClient.getOrder(id: orderId)
            order = detail
            savedCopyAt = nil
            keepCopy(of: detail)
        } catch let error as MVError where error.mvIsNotFound {
            wasDeleted = true
        } catch {
            if error.mvIsCancellation {
                // Superseded by a newer load; nothing to show.
            } else if order != nil {
                // A refresh that fails leaves the order on screen as it is: a ticket on show at a
                // gate must not turn into an error page because the network blinked.
            } else if error.mvIsServerUnreachable, let saved = await offlineCache?.order(id: orderId) {
                order = saved.detail
                savedCopyAt = saved.savedAt
            } else {
                errorMessage = error.mvUserMessage
            }
        }
        isLoading = false
    }

    private func keepCopy(of detail: OrderDetail) {
        guard let offlineCache else { return }
        let api = apiClient
        Task { await OrderOfflineCopy.save(detail, api: api, in: offlineCache) }
    }

    /// The PNG of a code fact: the saved copy when there is one (a fact id names one code for as
    /// long as it exists), otherwise drawn by the server and saved.
    public func codeImage(for fact: OrderFactOut) async -> Data? {
        guard let code = fact.code else { return nil }
        if let saved = await offlineCache?.orderCode(factId: fact.id) { return saved }
        guard let png = try? await apiClient.getOrderCodeImage(code: code) else { return nil }
        await offlineCache?.saveOrderCode(png, factId: fact.id)
        return png
    }

    public func presentCode(_ fact: OrderFactOut) {
        guard fact.code != nil else { return }
        presentedCodeFactId = fact.id
    }

    /// The bytes of a document of this order: a mail attachment or a file added by hand.
    public func downloadDocument(_ document: OrderDocumentOut) async throws -> Data {
        guard let path = document.downloadUrl else {
            throw MVError.detail("This document is no longer available.", statusCode: 404)
        }
        return try await apiClient.getOrderResource(path: path).data
    }

    /// Overrides the kind; the model's rewrites leave a person's choice alone from then on.
    public func setKind(_ kind: OrderKind) async throws {
        guard order != nil else { return }
        order = try await apiClient.updateOrder(id: orderId, OrderUpdateRequest(kind: kind))
    }

    /// Adds a file to this order. The server reads and places it in the background: the entry shows
    /// as analysing until it is attached, then the order is read again.
    public func addFile(data: Data, filename: String, contentType: String) async {
        var upload = OrderUpload(filename: filename)
        uploads.append(upload)
        func update(_ state: OrderUpload.Phase) {
            upload.state = state
            if let index = uploads.firstIndex(where: { $0.id == upload.id }) { uploads[index] = upload }
        }
        func finish() {
            uploads.removeAll { $0.id == upload.id }
        }
        do {
            var status = try await apiClient.uploadOrderFile(
                data: data, filename: filename, contentType: contentType, orderId: orderId)
            update(.analysing)
            var polls = 0
            while status.isPending, polls < uploadPollLimit {
                try? await Task.sleep(for: uploadPollInterval)
                status = try await apiClient.getOrderFileStatus(fileId: status.fileId)
                polls += 1
            }
            if status.isAttached {
                finish()
                await load()
            } else if status.isFailed {
                update(.failed(status.lastError ?? "The file could not be read."))
            } else {
                update(.failed("Taking longer than usual. It appears here once it has been read."))
            }
        } catch {
            update(.failed(error.mvUserMessage))
        }
    }

    public func dismissUpload(_ id: UUID) {
        uploads.removeAll { $0.id == id }
    }

    /// Deletes a file added by hand, with its document and codes. Deleting the last thing in an
    /// order deletes the order, which the next read reports as a 404.
    public func deleteFile(_ document: OrderDocumentOut) async throws {
        guard let fileId = document.fileId else { return }
        try await apiClient.deleteOrderFile(orderId: orderId, fileId: fileId)
        await load()
    }

    /// Enqueues a manual rewrite -- `order.textStale` (refreshed on the next `load()`, or the
    /// live `order.updated` this causes) is what tells the screen a new summary is on its way.
    public func rewrite() async throws {
        try await apiClient.rewriteOrder(id: orderId)
    }

    /// Runs one of the order actions on this order; returns the toast text, or `nil` when the
    /// action has none. A flag flip adopts the order the server reports back.
    @discardableResult
    public func perform(_ action: OrderAction) async throws -> String? {
        guard let order else { return nil }
        if let toggle = OrderActionSet.toggle(action, order.flags) {
            self.order = try await apiClient.updateOrder(id: orderId, toggle.update)
            return toggle.message
        }
        switch action {
        case .rewrite:
            try await rewrite()
            return "Rewriting the summary…"
        case .delete:
            try await delete()
            return nil
        case .favorite, .close, .seal:
            return nil
        }
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
