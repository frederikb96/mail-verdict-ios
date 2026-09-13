import Foundation
import Observation

// URLSession and friends live in FoundationNetworking on Linux, where the free CI runner builds
// this package. On Apple platforms the module does not exist and Foundation already has them.
#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif

/// A store that wants to hear about live updates — the mail list, search, spam review, the
/// Mailboxes/accounts overview, and so on. One subscriber, one conformance; `LiveEventHub` holds
/// it weakly, so a store that is deallocated without explicitly unsubscribing is simply dropped
/// rather than leaked or crashing.
@MainActor
public protocol LiveEventSubscriber: AnyObject {
    /// Every invalidation since the last delivery to this subscriber — an immediate one
    /// (`alert.new`, `outbox.updated`, …) arrives alone; a mail burst (`mail.new`/`.updated`/
    /// `.deleted`, `folder.synced`) arrives as however many coalesced within the same 500 ms
    /// window. One method for both, so a subscriber has exactly one place to react from.
    func apply(_ invalidations: [MVLiveInvalidation])

    /// Whether the live connection is currently up. A subscriber that does not act on connection
    /// state can ignore this — the default below is a no-op.
    func setConnected(_ connected: Bool)
}

extension LiveEventSubscriber {
    public func setConnected(_ connected: Bool) {}
}

public typealias MVSubscriptionToken = UUID

/// What `LiveEventHub.connectionState` reports — a list's own subtitle ("Connecting…" for
/// reconnecting, "Offline" for disconnected) reads this directly. `MVSseClient` retries with
/// capped backoff forever once told to connect, so losing the stream always becomes
/// `.reconnecting`, never `.disconnected` — that state is reserved for an explicit `disconnect()`
/// (signed out, or never connected yet).
public enum MVConnectionState: Sendable, Equatable {
    case disconnected
    case reconnecting
    case connected
}

/// Consumes `GET /api/events` over `MVSseClient` and publishes typed invalidations to every
/// subscribed store — `LiveEventHubMappingTests` is the proof every SSE event name this app
/// knows about maps to the right invalidation.
///
/// One instance for the whole app, owned by `AppEnvironment` — never one per screen, since the
/// backend's own event ring has no notion of "this SSE connection is for screen X" and opening a
/// second one buys nothing but a second reconnect/backoff cycle to manage.
///
/// Mail-burst events (`mail.new`/`.updated`/`.deleted`, `folder.synced`) are coalesced and
/// delivered at most once every 500 ms — an initial sync inserting hundreds of rows in a few
/// seconds would otherwise ask every open list to re-render hundreds of times. Everything else is
/// delivered the moment it arrives: a toast, a badge or a settings refetch should never wait on a
/// timer for no reason.
@MainActor
@Observable
public final class LiveEventHub {

    public private(set) var connectionState: MVConnectionState = .disconnected

    /// `connectionState` as a screen should show it: a reconnect that finishes within
    /// `reconnectingGraceNanos` — launch, a return from the background, a proxy recycling the
    /// stream — never surfaces, so "Connecting…" means the connection is genuinely struggling.
    public private(set) var visibleConnectionState: MVConnectionState = .connected

    public static let reconnectingGraceNanos: UInt64 = 3_000_000_000
    private static let flushIntervalNanos: UInt64 = 500_000_000
    @ObservationIgnored private var visibleStateTask: Task<Void, Never>?

    private let sseClient: MVSseClient
    private var pending: [MVLiveInvalidation] = []
    private var flushTask: Task<Void, Never>?

    /// Weak so a subscriber that forgets to `unsubscribe` before going away is dropped, not
    /// leaked — `ObservationIgnored` because neither the box nor what it wraps is itself part of
    /// this hub's own observable state.
    @ObservationIgnored
    private var subscribers: [MVSubscriptionToken: WeakSubscriberBox] = [:]

    private final class WeakSubscriberBox {
        weak var subscriber: (any LiveEventSubscriber)?
        init(_ subscriber: any LiveEventSubscriber) { self.subscriber = subscriber }
    }

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
        urlSessionConfiguration: URLSessionConfiguration = .default
    ) {
        let box = HubBox()
        self.sseClient = MVSseClient(
            accountId: accountId,
            requestFactory: requestFactory,
            callbacks: .init(
                onRecord: { record in box.hub?.handle(record) },
                onActivity: {},
                onConnected: { box.hub?.setConnectionState(.connected) },
                onDisconnected: { box.hub?.handleStreamDisconnected() }
            ),
            urlSessionConfiguration: urlSessionConfiguration
        )
        box.hub = self
    }

    public func connect() {
        connectionState = .reconnecting
        updateVisibleState()
        sseClient.connect()
        scheduleFlush()
    }

    public func disconnect() {
        sseClient.disconnect()
        flushTask?.cancel()
        flushTask = nil
        setConnectionState(.disconnected)
    }

    /// The app went to the background: the stream is closed rather than left to die unobserved.
    /// Subscribers are not told — nothing is on screen, and `resume()` replays what was missed.
    public func pause() {
        guard connectionState != .disconnected else { return }
        sseClient.pause()
        connectionState = .reconnecting
    }

    /// Back in the foreground: reconnect now, not after whatever backoff had accumulated.
    public func resume() {
        guard connectionState != .disconnected else { return }
        sseClient.resume()
        updateVisibleState()
    }

    private func updateVisibleState() {
        visibleStateTask?.cancel()
        visibleStateTask = nil
        guard connectionState == .reconnecting else {
            visibleConnectionState = connectionState
            return
        }
        guard visibleConnectionState != .reconnecting else { return }
        if visibleConnectionState == .disconnected { visibleConnectionState = .connected }
        visibleStateTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: Self.reconnectingGraceNanos)
            guard let self, !Task.isCancelled, self.connectionState == .reconnecting else { return }
            self.visibleConnectionState = .reconnecting
        }
    }

    /// Registers `subscriber` (held weakly) and immediately tells it the current connection
    /// state, so a store that subscribes after the hub is already connected does not sit showing
    /// "offline" until the next state change.
    @discardableResult
    public func subscribe(_ subscriber: any LiveEventSubscriber) -> MVSubscriptionToken {
        let token = MVSubscriptionToken()
        subscribers[token] = WeakSubscriberBox(subscriber)
        subscriber.setConnected(connectionState == .connected)
        return token
    }

    public func unsubscribe(_ token: MVSubscriptionToken) {
        subscribers[token] = nil
    }

    private func setConnectionState(_ state: MVConnectionState) {
        connectionState = state
        updateVisibleState()
        broadcastConnected(state == .connected)
    }

    private func handleStreamDisconnected() {
        connectionState = .reconnecting
        updateVisibleState()
        broadcastConnected(false)
    }

    private func broadcastConnected(_ connected: Bool) {
        pruneDeadSubscribers()
        for box in subscribers.values {
            box.subscriber?.setConnected(connected)
        }
    }

    private func handle(_ record: MVSseRecord) {
        let invalidation = Self.mapRecord(record)
        switch invalidation {
        case .mailNew, .mailUpdated, .mailDeleted, .folderSynced:
            pending.append(invalidation)
        default:
            deliver([invalidation])
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
        deliver(batch)
    }

    private func deliver(_ batch: [MVLiveInvalidation]) {
        pruneDeadSubscribers()
        for box in subscribers.values {
            box.subscriber?.apply(batch)
        }
    }

    private func pruneDeadSubscribers() {
        subscribers = subscribers.filter { $0.value.subscriber != nil }
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
            // A calendar reply's outbox row routes to the invitation card and event detail,
            // never a mail toast or list refresh.
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
