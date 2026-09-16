import Foundation

/// What the reader pager needs from whichever list it is paging through — implemented by the
/// mail list, search results and spam-review stores alike, so `ReaderPagingStore`
/// pages through any of them identically rather than special-casing each.
///
/// `@MainActor`: every implementation is a UI-facing store, and the pager reads these properties
/// on every settle, so there is no benefit to a thread-safety story broader than "the main actor".
@MainActor
public protocol ReaderListSource: AnyObject {
    /// Every row currently loaded, in display order — what `ReaderPagingStore` walks through
    /// `ReaderNeighbourResolver` to find a message's neighbours.
    var rowIds: [UUID] { get }
    var hasOlder: Bool { get }
    var hasNewer: Bool { get }

    /// Loads the next older page. A no-op, not an error, once `hasOlder` is already `false`.
    func loadOlder() async

    /// Loads the next newer page. A no-op, not an error, once `hasNewer` is already `false`.
    func loadNewer() async

    /// The reader's own nav title for this source — "{N} Messages" for a folder or unified view,
    /// "{total} Results" for search, "{n} to Review" for spam review. `nil`
    /// while the count this is built from has not loaded yet.
    ///
    /// A protocol requirement, not only an extension member with a default: a call through `any
    /// ReaderListSource` dispatches an extension-only member statically (to the extension's own
    /// default), never reaching a conformer's override — only a requirement dispatches
    /// dynamically to what the conformer actually implements.
    var readerTitle: String? { get }
}

extension ReaderListSource {
    public var readerTitle: String? { nil }
}
