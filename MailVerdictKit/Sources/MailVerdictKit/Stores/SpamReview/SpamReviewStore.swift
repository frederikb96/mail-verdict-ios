import Foundation
import Observation

/// The result of a bulk Accept All / Reject All run — the UX design's own toast text depends on
/// whether everything succeeded.
public struct MVSpamReviewBulkResult: Sendable, Equatable {
    public let succeeded: Int
    public let failed: Int
    public let attempted: Int

    public init(succeeded: Int, failed: Int, attempted: Int) {
        self.succeeded = succeeded
        self.failed = failed
        self.attempted = attempted
    }
}

/// Everything current classifies as spam with no ruling on it yet, across every account and
/// folder including Junk — a view over verdicts, not a folder. `ReaderListSource` so a tap opens
/// the reader paging through the loaded batch in the same order.
@Observable
@MainActor
public final class SpamReviewStore {
    public private(set) var items: [SpamReviewItem] = []
    public private(set) var isLoading = false
    public private(set) var isLoadingMore = false
    public private(set) var errorMessage: String?
    public private(set) var isBulkRunning = false
    private var hasMore = false
    private var nextCursor: String?

    private let apiClient: MVApiClient

    public init(apiClient: MVApiClient) {
        self.apiClient = apiClient
    }

    public func load() async {
        isLoading = items.isEmpty
        errorMessage = nil
        do {
            let response = try await apiClient.listSpamReview(limit: 50)
            items = response.items
            hasMore = response.hasMore
            nextCursor = response.nextCursor
        } catch {
            errorMessage = (error as? MVError)?.userMessage ?? "\(error)"
        }
        isLoading = false
        reportDebugState()
    }

    public func loadMore() async {
        guard hasMore, !isLoadingMore else { return }
        isLoadingMore = true
        if let response = try? await apiClient.listSpamReview(before: nextCursor.flatMap(UUID.init(uuidString:))) {
            items.append(contentsOf: response.items)
            hasMore = response.hasMore
            nextCursor = response.nextCursor
        }
        isLoadingMore = false
        reportDebugState()
    }

    /// Thumb up (`agree: true`) confirms the spam verdict; thumb down (`agree: false`) corrects
    /// it — one call does both the record and the move regardless of where the message currently
    /// sits (a message the pipeline never moved is already in the inbox, so a reject there is a
    /// no-op move, not a special case to route around). Removes the row on success either way.
    public func decide(_ item: SpamReviewItem, agree: Bool) async throws {
        _ = try await apiClient.submitFeedback(messageId: item.messageId, accountId: item.accountId, isSpam: agree)
        items.removeAll { $0.messageId == item.messageId }
        reportDebugState()
    }

    /// "Everything currently listed" — the loaded batch, not the whole matching set: verdicts are
    /// corrected one at a time server-side and there is nothing like a bulk-action scope for this
    /// query, the same reasoning `spam-review-page.tsx` documents.
    public func decideAll(agree: Bool) async -> MVSpamReviewBulkResult {
        let batch = items
        isBulkRunning = true
        var succeeded = 0
        await withTaskGroup(of: Bool.self) { group in
            for item in batch {
                group.addTask { [apiClient] in
                    (try? await apiClient.submitFeedback(
                        messageId: item.messageId, accountId: item.accountId, isSpam: agree
                    )) != nil
                }
            }
            for await ok in group where ok { succeeded += 1 }
        }
        items.removeAll { item in batch.contains { $0.messageId == item.messageId } }
        isBulkRunning = false
        reportDebugState()
        return MVSpamReviewBulkResult(succeeded: succeeded, failed: batch.count - succeeded, attempted: batch.count)
    }

    private func reportDebugState() {
        #if DEBUG
            SpamReviewDebugReporter.shared.report(
                MVSpamReviewDebugSnapshot(itemCount: items.count, hasMore: hasMore)
            )
        #endif
    }
}

extension SpamReviewStore: ReaderListSource {
    public var rowIds: [UUID] { items.map(\.messageId) }
    public var hasOlder: Bool { hasMore }
    public var hasNewer: Bool { false }

    public func neighbours(of messageId: UUID) -> (older: UUID?, newer: UUID?) {
        guard let index = items.firstIndex(where: { $0.messageId == messageId }) else { return (nil, nil) }
        let older = index + 1 < items.count ? items[index + 1].messageId : nil
        let newer = index > 0 ? items[index - 1].messageId : nil
        return (older, newer)
    }

    public func loadOlder() async { await loadMore() }
    public func loadNewer() async {}

    public var readerTitle: String? { "\(items.count) to Review" }
}
