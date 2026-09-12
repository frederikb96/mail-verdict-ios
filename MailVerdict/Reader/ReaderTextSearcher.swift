import MailVerdictKit
import UIKit

/// Find in Message: the system find panel, searching the opened message's own body through
/// `reader.js`. Apple's `UITextSearchingFindSession` drives the panel; this object answers it,
/// reporting each match as an opaque range the script can highlight by index. Matches are painted,
/// never wrapped in markup, so a search leaves the page's layout alone.
///
/// UIKit calls `UITextSearching` on the main thread but declares it without isolation, so each
/// requirement is `nonisolated` and hops to the main actor carrying only plain values.
@MainActor
final class ReaderTextSearcher: NSObject, UITextSearching {
    typealias DocumentIdentifier = Int

    private weak var page: MessagePageView?
    private(set) var resultCount = 0

    init(page: MessagePageView) {
        self.page = page
    }

    nonisolated var selectedTextRange: UITextRange? { nil }

    nonisolated func compare(_ foundRange: UITextRange, toRange: UITextRange, document: Int?) -> ComparisonResult {
        let lhs = (foundRange as? ReaderFoundRange)?.index ?? 0
        let rhs = (toRange as? ReaderFoundRange)?.index ?? 0
        return lhs < rhs ? .orderedAscending : (lhs > rhs ? .orderedDescending : .orderedSame)
    }

    nonisolated func performTextSearch(
        queryString: String, options: UITextSearchOptions, resultAggregator: UITextSearchAggregator<Int>
    ) {
        nonisolated(unsafe) let aggregator = resultAggregator
        Task { @MainActor [weak self] in
            let count = await self?.page?.find(queryString) ?? 0
            self?.resultCount = count
            for index in 0..<count {
                aggregator.foundRange(ReaderFoundRange(index: index), searchString: queryString, document: 0)
            }
            aggregator.finishedSearching()
        }
    }

    nonisolated func decorate(foundTextRange: UITextRange, document: Int?, usingStyle style: UITextSearchFoundTextStyle)
    {
        guard style == .highlighted, let index = (foundTextRange as? ReaderFoundRange)?.index else { return }
        Task { @MainActor [weak self] in
            await self?.page?.highlight(index)
        }
    }

    nonisolated func clearAllDecoratedFoundText() {
        Task { @MainActor [weak self] in
            self?.resultCount = 0
            await self?.page?.clearFind()
        }
    }

    /// Highlighting a match already scrolls it to the centre of the page.
    nonisolated func scrollRangeToVisible(_ range: UITextRange, inDocument: Int?) {}
}

/// One match, identified by its position in the script's own list of matches.
final class ReaderFoundRange: UITextRange {
    nonisolated let index: Int
    private let startPosition: ReaderFoundPosition
    private let endPosition: ReaderFoundPosition

    init(index: Int) {
        self.index = index
        self.startPosition = ReaderFoundPosition(offset: index)
        self.endPosition = ReaderFoundPosition(offset: index + 1)
        super.init()
    }

    override var start: UITextPosition { startPosition }
    override var end: UITextPosition { endPosition }
    override var isEmpty: Bool { false }
}

final class ReaderFoundPosition: UITextPosition {
    let offset: Int

    init(offset: Int) {
        self.offset = offset
        super.init()
    }
}
