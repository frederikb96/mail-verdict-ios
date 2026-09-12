import Foundation

// URLSession and friends live in FoundationNetworking on Linux, where the free CI runner builds
// this package. On Apple platforms the module does not exist and Foundation already has them.
#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif

/// Consumes `GET /api/events` over `MVSseClient` and publishes typed invalidations — the UX
/// design's event table (§2.0, amended by the calendar-invitation addendum) as its test matrix,
/// `LiveEventHubMappingTests` as the proof every row is covered.
///
/// Mail-burst events (`mail.new`/`.updated`/`.deleted`, `folder.synced`) are coalesced and
/// delivered at most once every 500 ms — an initial sync inserting hundreds of rows in a few
/// seconds would otherwise ask every open list to re-render hundreds of times. Everything else is
/// delivered the moment it arrives: a toast, a badge or a settings refetch should never wait on a
/// timer for no reason.
@MainActor
public final class LiveEventHub {

    public struct Callbacks: Sendable {
        public var onBufferedInvalidations: @MainActor @Sendable ([MVLiveInvalidation]) -> Void
        public var onInvalidation: @MainActor @Sendable (MVLiveInvalidation) -> Void
        public var onConnectionStateChanged: @MainActor @Sendable (Bool) -> Void

        public init(
            onBufferedInvalidations: @escaping @MainActor @Sendable ([MVLiveInvalidation]) -> Void,
            onInvalidation: @escaping @MainActor @Sendable (MVLiveInvalidation) -> Void,
            onConnectionStateChanged: @escaping @MainActor @Sendable (Bool) -> Void
        ) {
            self.onBufferedInvalidations = onBufferedInvalidations
            self.onInvalidation = onInvalidation
            self.onConnectionStateChanged = onConnectionStateChanged
        }
    }

    private static let flushIntervalNanos: UInt64 = 500_000_000

    private let sseClient: MVSseClient
    private let callbacks: Callbacks
    private var pending: [MVLiveInvalidation] = []
    private var flushTask: Task<Void, Never>?

    /// `MVSseClient.Callbacks` needs every closure at construction time, before `self` exists to
    /// capture — a weak box built first and pointed at `self` afterwards stands in, rather than
    /// widening `MVSseClient`'s own API with a callback setter it otherwise never needs.
    // `@unchecked Sendable`: the one write (`box.hub = self`, right after `sseClient` is built)
    // happens-before `connect()` can ever be called, which is the only thing that lets the SSE
    // callbacks captured above run at all — so every read of `hub` is ordered after that write.
    private final class HubBox: @unchecked Sendable {
        weak var hub: LiveEventHub?
    }

    public init(
        accountId: String? = nil,
        requestFactory: MVRequestFactory,
        callbacks: Callbacks,
        urlSessionConfiguration: URLSessionConfiguration = .default
    ) {
        self.callbacks = callbacks
        let box = HubBox()
        self.sseClient = MVSseClient(
            accountId: accountId,
            requestFactory: requestFactory,
            callbacks: .init(
                onRecord: { record in box.hub?.handle(record) },
                onActivity: {},
                onConnected: { box.hub?.callbacks.onConnectionStateChanged(true) },
                onDisconnected: { box.hub?.callbacks.onConnectionStateChanged(false) }
            ),
            urlSessionConfiguration: urlSessionConfiguration
        )
        box.hub = self
    }

    public func connect() {
        sseClient.connect()
        scheduleFlush()
    }

    public func disconnect() {
        sseClient.disconnect()
        flushTask?.cancel()
        flushTask = nil
    }

    private func handle(_ record: MVSseRecord) {
        let invalidation = Self.mapRecord(record)
        switch invalidation {
        case .mailNew, .mailUpdated, .mailDeleted, .folderSynced:
            pending.append(invalidation)
        default:
            callbacks.onInvalidation(invalidation)
        }
    }

    private func scheduleFlush() {
        flushTask?.cancel()
        flushTask = Task { [weak self] in
            while true {
                try? await Task.sleep(nanoseconds: Self.flushIntervalNanos)
                guard let self, !Task.isCancelled else { return }
                self.flush()
            }
        }
    }

    private func flush() {
        guard !pending.isEmpty else { return }
        let batch = pending
        pending = []
        callbacks.onBufferedInvalidations(batch)
    }

    // MARK: - Mapping (pure, tested directly — see LiveEventHubMappingTests)

    nonisolated static func mapRecord(_ record: MVSseRecord) -> MVLiveInvalidation {
        guard let name = SSEEventName(rawValue: record.name) else {
            return .unknown(record.name)
        }
        let json = MVSseJSON(record.data)
        switch name {
        case .connected:
            // MVSseClient itself already captures `record.id` as the next `Last-Event-ID` —
            // nothing left for a store to react to.
            return .ignored(name)
        case .resync:
            return .resync
        case .mailNew:
            return .mailNew(
                accountId: json.uuid("account_id"), folderId: json.uuid("folder_id"),
                messageId: json.uuid("id")
            )
        case .mailUpdated:
            return .mailUpdated(
                accountId: json.uuid("account_id"), folderId: json.uuid("folder_id"),
                messageId: json.uuid("id"), changed: json.stringArray("changed")
            )
        case .mailDeleted:
            return .mailDeleted(
                accountId: json.uuid("account_id"), folderId: json.uuid("folder_id"),
                messageId: json.uuid("id")
            )
        case .verdictIssued:
            return .verdictIssued(
                accountId: json.uuid("account_id"), messageId: json.uuid("message_id"),
                isSpam: json.bool("is_spam")
            )
        case .alertNew, .alertDismissed:
            return .alertsChanged
        case .notificationNew:
            return .notificationsChanged
        case .accountChanged:
            return .accountsChanged
        case .folderSynced:
            // The payload carries only folder_id and backfill -- account_id scopes the ring
            // subscription, it is never in the JSON body itself.
            return .folderSynced(accountId: nil, folderId: json.uuid("folder_id"))
        case .folderChanged:
            return .foldersChanged
        case .outboxUpdated:
            let payload = MVOutboxEventPayload(
                id: json.uuid("id"), changed: json.stringArray("changed"),
                status: json.string("status"), kind: json.string("kind"), itip: json.string("itip")
            )
            // The addendum's own amendment: a calendar reply's outbox row routes to the
            // invitation card and event detail, never a mail toast or list refresh.
            return payload.itip == "reply" ? .invitationOrEventChanged : .outboxUpdated(payload)
        case .settingsChanged:
            return .settingsChanged(category: json.string("category"))
        case .identityChanged:
            return .identitiesChanged(accountId: json.uuid("account_id"))
        case .calendarObject:
            return .invitationOrEventChanged
        case .calendarAccount, .calendarCollection, .calendarLinksChanged, .contactCollection,
            .contactObject, .pipelineDocumentChanged, .pipelineNotify, .pipelineRunFinished:
            return .ignored(name)
        }
    }
}

/// A tiny, forgiving reader over one SSE record's JSON body — never throws, since a record this
/// client cannot fully parse should still be classified (a missing or malformed field inside an
/// otherwise-recognized event is not a reason to drop the whole invalidation).
struct MVSseJSON {
    private let object: [String: Any]

    init(_ raw: String) {
        let data = Data(raw.utf8)
        object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
    }

    func string(_ key: String) -> String? {
        object[key] as? String
    }

    func uuid(_ key: String) -> UUID? {
        (object[key] as? String).flatMap(UUID.init(uuidString:))
    }

    func bool(_ key: String) -> Bool? {
        object[key] as? Bool
    }

    func stringArray(_ key: String) -> [String] {
        (object[key] as? [String]) ?? []
    }
}
