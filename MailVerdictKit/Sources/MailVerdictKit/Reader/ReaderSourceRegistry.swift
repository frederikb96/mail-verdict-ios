import Foundation

/// How the reader finds the list it pages through. The list, search and spam-review stores live
/// in their own screens; each registers here when its screen appears, keyed by the same
/// `ReaderContext.Source` its rows push the reader with. A reader opened with nothing registered
/// — a notification tap landing before the list exists — shows only the opened message.
@MainActor
public final class ReaderSourceRegistry {
    public static let shared = ReaderSourceRegistry()

    private final class WeakSource {
        weak var source: (any ReaderListSource)?
        init(_ source: any ReaderListSource) { self.source = source }
    }

    private var sources: [ReaderContext.Source: WeakSource] = [:]
    private var lastSettled: [ReaderContext.Source: UUID] = [:]

    public init() {}

    public func register(_ source: any ReaderListSource, for key: ReaderContext.Source) {
        sources[key] = WeakSource(source)
    }

    public func source(for key: ReaderContext.Source) -> (any ReaderListSource)? {
        sources[key]?.source
    }

    /// The row the reader last settled on for this list — what the list scrolls to, minimally,
    /// when the reader returns to it having paged away from the row it opened.
    public func lastSettledMessageId(for key: ReaderContext.Source) -> UUID? {
        lastSettled[key]
    }

    public func recordSettled(_ messageId: UUID, for key: ReaderContext.Source) {
        lastSettled[key] = messageId
    }
}

/// Adopted by a source that can name itself in the reader's title — "{N} Messages" for a folder
/// or view, "{total} Results" for search, "{n} to Review" for spam review. `nil` while unknown.
@MainActor
public protocol ReaderTitledSource: ReaderListSource {
    var readerTitle: String? { get }
}

/// Adopted by a source whose rows can stand for whole conversations (the list grouped by
/// conversation): the reader then marks the rest of a row's conversation read when it settles on
/// it, as opening a grouped row does on the web.
@MainActor
public protocol ReaderConversationScopedSource: ReaderListSource {
    /// The folders a row's conversation is read within, or `nil` when rows are single messages.
    func conversationFolderIds(for messageId: UUID) -> [UUID]?
}

extension MVExplicitUnreadTracker {
    /// The one "explicitly marked unread" id every surface shares — the list's Mark as Unread must
    /// set it too, or opening that message would mark it read again straight away.
    public static let shared = MVExplicitUnreadTracker()
}
