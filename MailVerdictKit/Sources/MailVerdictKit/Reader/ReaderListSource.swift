import Foundation

/// What the reader pager needs from whichever list it is paging through — implemented by the
/// mail list, search results and spam-review stores alike (S1, S5, S6), so `ReaderPagingStore`
/// pages through any of them identically rather than special-casing each.
///
/// `@MainActor`: every implementation is a UI-facing store, and the pager reads these properties
/// on every settle, so there is no benefit to a thread-safety story broader than "the main actor".
@MainActor
public protocol ReaderListSource: AnyObject {
    /// Every row currently loaded, in display order — what `neighbours(of:)` walks.
    var rowIds: [UUID] { get }
    var hasOlder: Bool { get }
    var hasNewer: Bool { get }

    /// `nil` for either side when `messageId` is the first/last loaded row, or is not present at
    /// all (a row removed by a live delete between settling and the next neighbour lookup).
    func neighbours(of messageId: UUID) -> (older: UUID?, newer: UUID?)

    /// Loads the next older page. A no-op, not an error, once `hasOlder` is already `false`.
    func loadOlder() async

    /// Loads the next newer page. A no-op, not an error, once `hasNewer` is already `false`.
    func loadNewer() async
}
