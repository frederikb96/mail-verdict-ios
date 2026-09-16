import Foundation
import Observation

/// Something holding server data the ledger's intents are projected over — a list, the reader.
@MainActor
public protocol MVIntentObserver: AnyObject {
    /// Rows this holds for `messageIds`, kept on a new intent so an undone move can put them back.
    func intentSnapshots(for messageIds: Set<UUID>) -> [MessageSummary]
    /// These done intents are leaving the ledger: data read before they settled keeps their effect.
    func intentsWillRetire(_ intents: [MVMailIntent])
    /// These intents reached the server, or found their message gone.
    func intentsDidSettle(_ intents: [MVMailIntent])
}

extension MVIntentObserver {
    public func intentSnapshots(for messageIds: Set<UUID>) -> [MessageSummary] { [] }
    public func intentsDidSettle(_ intents: [MVMailIntent]) {}
}

/// Every mail action between a person and the server: durable, delivered in order, retried, and
/// undoable. One instance per connection, shared by every list and the reader.
///
/// Each account drains serially — one request out at a time, in the order the actions were
/// taken, and never an intent ahead of an earlier one touching the same message, so a mark-read
/// and an archive of one message always arrive in that order.
///
/// - A request that gets no answer, a timeout, a 429 or a 5xx is retried with backoff, up to
///   `Timing.maxAttempts`; then it fails visibly. Before retrying one that may already have been
///   applied, the ledger reads the messages and treats an action they already show as done — a
///   server that ignores the idempotency key would otherwise apply it twice.
/// - While the device is offline nothing is sent; everything goes the moment it is back.
/// - A 401, 403 or login-proxy answer holds everything, unsent and unfailed, until the app is
///   signed in again (a new ledger picks the persisted intents up) or returns to the foreground.
/// - Any other 4xx refuses the intent; a 404 means the message is gone and the intent retires.
/// - An intent still unsent after `Timing.pendingExpiry` is not sent on its own: the mailbox may
///   have moved on since, so the person sends or discards it (`unsentIntents`).
@Observable
@MainActor
public final class MVIntentLedger {

    public struct Timing: Sendable {
        /// Replaces the session's minute-long default for every request the ledger makes.
        public var requestTimeout: TimeInterval = 20
        /// How long a request may be out before its rows say they are waiting.
        public var waitingAfter: TimeInterval = 0.8
        public var backoffBase: TimeInterval = 1
        public var backoffCap: TimeInterval = 60
        /// Attempts before a retrying intent fails and asks for Retry or Discard.
        public var maxAttempts = 8
        /// How long an intent may stay unsent before it is held for the person to confirm.
        public var pendingExpiry: TimeInterval = 3600
        /// How long a done intent stays. It stops applying the moment data read after it lands —
        /// that read is the server agreeing — but stays this long to be undone, and so that a read
        /// begun before it settled has landed or failed before its effect is folded in for good.
        public var doneRetention: TimeInterval = 90
        /// How long a failed intent keeps marking its rows and offering Retry.
        public var failedRetention: TimeInterval = 86_400
        /// Past this many messages, an intent that may have landed is sent again without reading
        /// each message first; the idempotency key alone keeps that safe.
        public var reconcileLimit = 25

        public init() {}
    }

    /// Creation order. Open intents first applied, done ones kept until retired.
    public private(set) var intents: [MVMailIntent] = []
    /// Bumped whenever an intent settles. Data records it when its read begins
    /// (`MVIntentProjection.applies`).
    public private(set) var sequence = 0
    /// Open intents that have been waiting long enough to say so.
    public private(set) var waitingIds: Set<UUID> = []
    /// The credential or the login proxy was refused; nothing goes out until the app is signed in
    /// again or comes back to the foreground.
    public private(set) var isHeld = false

    @ObservationIgnored private let transport: any MVIntentTransport
    @ObservationIgnored private let persistence: any MVIntentPersistence
    @ObservationIgnored private let clock: any MVIntentClock
    @ObservationIgnored private let connectivity: any MVConnectivity
    @ObservationIgnored private let toasts: MVToastStore?
    @ObservationIgnored private let timing: Timing
    @ObservationIgnored private var observers: [WeakObserver] = []
    @ObservationIgnored private var workers: [UUID: Task<Void, Never>] = [:]
    @ObservationIgnored private var sleepers: [UUID: Task<Void, Never>] = [:]
    @ObservationIgnored private var retirementTask: Task<Void, Never>?
    @ObservationIgnored private var callbacks: [UUID: @MainActor (MVIntentOutcome) -> Void] = [:]
    @ObservationIgnored private var idleWaiters: [CheckedContinuation<Void, Never>] = []
    @ObservationIgnored private var isStopped = false

    private final class WeakObserver {
        weak var observer: (any MVIntentObserver)?
        init(_ observer: any MVIntentObserver) { self.observer = observer }
    }

    /// Loads what the last launch left. A request that was out may have landed, so it is checked
    /// before being sent again; one undone while it was out is reversed; a done one is dropped,
    /// since every read from now on already has it.
    public init(
        transport: any MVIntentTransport, persistence: any MVIntentPersistence,
        clock: any MVIntentClock = MVSystemIntentClock(), connectivity: any MVConnectivity,
        toasts: MVToastStore?, timing: Timing = Timing()
    ) {
        self.transport = transport
        self.persistence = persistence
        self.clock = clock
        self.connectivity = connectivity
        self.toasts = toasts
        self.timing = timing
        intents = persistence.load().compactMap { intent in
            var intent = intent
            switch intent.state {
            case .done: return nil
            case .sending:
                intent.state = .pending
                intent.mayHaveLanded = true
            case .pending, .failed: break
            }
            return intent
        }
        for intent in intents where intent.undoRequested && intent.isOpen {
            replaceWithReversal(intent.id)
        }
        changed()
        connectivity.observe { [weak self] online in
            if online { self?.resume() }
        }
        for accountId in Set(intents.filter(\.isOpen).map(\.accountId)) { startWorker(accountId) }
        scheduleRetirement()
    }

    // MARK: - Observers

    public func addObserver(_ observer: any MVIntentObserver) {
        observers.removeAll { $0.observer == nil || $0.observer === observer }
        observers.append(WeakObserver(observer))
    }

    private var liveObservers: [any MVIntentObserver] {
        observers.removeAll { $0.observer == nil }
        return observers.compactMap(\.observer)
    }

    // MARK: - Reading

    public func project(message: MessageDetail, baseSequence: Int) -> MessageDetail {
        MVIntentProjection.message(message, applying: intents, baseSequence: baseSequence)
    }

    /// Messages an intent has taken out of their folder and no later one has moved back — a
    /// reader paging a list that does not project intents itself skips them.
    public var hiddenMessageIds: Set<UUID> {
        var hidden: Set<UUID> = []
        for intent in intents where intent.leavesFolder && MVIntentProjection.applies(intent, over: 0) {
            if intent.undoes == nil {
                hidden.formUnion(intent.messageIds)
            } else {
                hidden.subtract(intent.messageIds)
            }
        }
        return hidden
    }

    public func rowState(for messageId: UUID) -> MVIntentRowState {
        var state = MVIntentRowState.none
        for intent in intents where intent.messageIds.contains(messageId) {
            switch intent.state {
            case .failed: state = .failed
            case .pending, .sending:
                if waitingIds.contains(intent.id) || intent.awaitingConfirmation { state = .waiting }
            case .done: break
            }
        }
        return state
    }

    /// "3 actions waiting for the network", or `nil` with nothing waiting.
    public var waitingSummary: String? {
        let waiting = waitingIds
        let count = intents.filter { $0.isOpen && !$0.awaitingConfirmation }.filter { waiting.contains($0.id) }.count
        guard count > 0 else { return nil }
        return "\(count) \(count == 1 ? "action" : "actions") waiting for the network"
    }

    /// Unsent past `Timing.pendingExpiry`, waiting for `confirmSend` or `discard`.
    public var unsentIntents: [MVMailIntent] { intents.filter { $0.isOpen && $0.awaitingConfirmation } }

    public var failedIntents: [MVMailIntent] { intents.filter { $0.state == .failed } }

    /// "2 actions not sent · 1 failed", or `nil` when nothing needs the person.
    public var attentionSummary: String? {
        var parts: [String] = []
        let unsent = unsentIntents.count
        let failed = failedIntents.count
        if unsent > 0 { parts.append("\(unsent) \(unsent == 1 ? "action" : "actions") not sent") }
        if failed > 0 { parts.append("\(failed) failed") }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    public var hasOpenIntents: Bool { intents.contains { $0.isOpen && !$0.awaitingConfirmation } }

    /// Returns once nothing is left to send — or the ledger stops, or everything left is waiting
    /// for the person.
    public func waitUntilIdle() async {
        guard hasOpenIntents, !isStopped else { return }
        await withCheckedContinuation { idleWaiters.append($0) }
    }

    // MARK: - Acting

    /// Records an action and starts delivering it. `undoToast` shows at once with Undo;
    /// `onSettled` runs once, when the intent is done, gone, refused or cancelled.
    @discardableResult
    public func enqueue(
        _ request: MVIntentRequest, undoToast: String? = nil,
        onSettled: (@MainActor (MVIntentOutcome) -> Void)? = nil
    ) -> UUID {
        let id = UUID()
        guard !isStopped else { return id }
        var request = request
        if request.snapshots.isEmpty {
            let wanted = Set(request.messageIds)
            request.snapshots = liveObservers.lazy.map { $0.intentSnapshots(for: wanted) }.first { !$0.isEmpty } ?? []
        }
        append(MVMailIntent(request: request, id: id, undoes: nil, createdAt: clock.now), onSettled: onSettled)
        if let undoToast { showUndo(undoToast, for: [id]) }
        return id
    }

    /// Shows `message` with an Undo for `ids`.
    public func showUndo(_ message: String, variant: MVToastVariant = .success, for ids: [UUID]) {
        toasts?.show(
            MVToast(
                variant: variant, message: message, duration: 6, actionTitle: "Undo",
                action: { [weak self] in Task { @MainActor in self?.undo(ids) } }))
    }

    /// Undoes intents. One that never left is dropped. One that may have reached the server — done,
    /// or attempted without an answer — is reversed by a new intent moving each message back (or
    /// flipping read and star back): a move to where a message already is changes nothing, so
    /// that is safe either way. One whose request is out stops applying at once and is reversed
    /// once the request settles.
    public func undo(_ ids: [UUID]) {
        guard !isStopped else { return }
        for id in ids {
            guard let index = intents.firstIndex(where: { $0.id == id }) else { continue }
            let intent = intents[index]
            switch intent.state {
            case .pending:
                if intent.attempts == 0 && !intent.mayHaveLanded {
                    intents.remove(at: index)
                    waitingIds.remove(id)
                    finish(id, .cancelled)
                } else {
                    replaceWithReversal(id)
                }
            case .sending:
                intents[index].undoRequested = true
            case .done:
                appendReversal(of: intent)
            case .failed:
                if intent.mayHaveLanded {
                    replaceWithReversal(id)
                } else {
                    intents.remove(at: index)
                }
            }
        }
        changed()
    }

    /// Unsent intents past their expiry, sent after all.
    public func confirmSend(_ ids: [UUID]) {
        guard !isStopped else { return }
        for index in intents.indices where ids.contains(intents[index].id) && intents[index].awaitingConfirmation {
            intents[index].awaitingConfirmation = false
            intents[index].sendConfirmed = true
            intents[index].nextAttemptAt = nil
        }
        changed()
        resume()
    }

    /// Unsent or failed intents given up on — undone, including whatever of them may have landed.
    public func discard(_ ids: [UUID]) {
        undo(ids)
    }

    /// Sends failed intents again from scratch.
    public func retry(_ ids: [UUID]) {
        guard !isStopped else { return }
        for index in intents.indices where ids.contains(intents[index].id) && intents[index].state == .failed {
            intents[index].state = .pending
            intents[index].attempts = 0
            intents[index].nextAttemptAt = nil
            intents[index].lastError = nil
            intents[index].settledSequence = nil
            intents[index].settledAt = nil
            intents[index].sendConfirmed = true
        }
        changed()
        resume()
    }

    /// Back in the foreground or back online: whatever is waiting on a backoff goes now.
    public func resume() {
        guard !isStopped else { return }
        isHeld = false
        for index in intents.indices where intents[index].state == .pending {
            intents[index].nextAttemptAt = nil
        }
        for accountId in Set(intents.filter(\.isOpen).map(\.accountId)) { startWorker(accountId) }
    }

    /// Ends delivery for good — the connection this ledger belongs to is going away. Nothing is
    /// written after this: open intents stay as persisted for the next ledger on the same server.
    public func stop() {
        isStopped = true
        for task in workers.values { task.cancel() }
        for task in sleepers.values { task.cancel() }
        retirementTask?.cancel()
        workers = [:]
        sleepers = [:]
        resumeIdleWaiters()
    }

    // MARK: - Delivery

    private func append(_ intent: MVMailIntent, onSettled: (@MainActor (MVIntentOutcome) -> Void)? = nil) {
        intents.append(intent)
        if let onSettled { callbacks[intent.id] = onSettled }
        changed()
        startWorker(intent.accountId)
    }

    private func startWorker(_ accountId: UUID) {
        guard !isStopped else { return }
        if workers[accountId] != nil {
            sleepers[accountId]?.cancel()
            return
        }
        workers[accountId] = Task { [weak self] in
            while let step = self?.nextStep(for: accountId) {
                switch step {
                case .send(let id):
                    await self?.send(id)
                case .wait(let seconds):
                    guard let sleeper = self?.sleeper(for: accountId, seconds: seconds) else { break }
                    await sleeper.value
                }
                if Task.isCancelled { break }
            }
            self?.workers[accountId] = nil
        }
    }

    private enum Step {
        case send(UUID)
        /// `nil`: until woken — the network returning, a new intent, or a confirmation.
        case wait(TimeInterval?)
    }

    private func nextStep(for accountId: UUID) -> Step? {
        guard !isStopped else { return nil }
        let open = intents.filter { $0.accountId == accountId && $0.isOpen && !$0.awaitingConfirmation }
        guard !open.isEmpty else { return nil }
        guard !isHeld else { return .wait(nil) }
        guard connectivity.isOnline else {
            waitingIds.formUnion(open.map(\.id))
            return .wait(nil)
        }
        let now = clock.now
        var blocked = Set(
            intents.filter { $0.accountId == accountId && $0.isOpen && $0.awaitingConfirmation }
                .flatMap(\.touchedMessageIds))
        var earliest: Date?
        for intent in open {
            if intent.state == .pending, blocked.isDisjoint(with: intent.touchedMessageIds) {
                if !intent.sendConfirmed && intent.createdAt.addingTimeInterval(timing.pendingExpiry) <= now {
                    holdForConfirmation(intent.id)
                    return nextStep(for: accountId)
                }
                guard let due = intent.nextAttemptAt, due > now else { return .send(intent.id) }
                earliest = min(earliest ?? due, due)
            }
            blocked.formUnion(intent.touchedMessageIds)
        }
        return .wait(earliest.map { $0.timeIntervalSince(now) })
    }

    private func holdForConfirmation(_ id: UUID) {
        guard let index = intents.firstIndex(where: { $0.id == id }) else { return }
        intents[index].awaitingConfirmation = true
        waitingIds.remove(id)
        changed()
    }

    private func sleeper(for accountId: UUID, seconds: TimeInterval?) -> Task<Void, Never> {
        let clock = clock
        let task = Task { _ = try? await clock.sleep(for: seconds ?? 3600) }
        sleepers[accountId] = task
        return task
    }

    private func send(_ id: UUID) async {
        guard let index = intents.firstIndex(where: { $0.id == id }) else { return }
        intents[index].state = .sending
        intents[index].attempts += 1
        let intent = intents[index]
        changed()

        let clock = clock
        let waitingAfter = timing.waitingAfter
        let marker = Task { [weak self] in
            guard (try? await clock.sleep(for: waitingAfter)) != nil else { return }
            self?.markWaiting(id)
        }
        var result: MVIntentDelivery?
        if intent.mayHaveLanded { result = await reconcile(intent) }
        if result == nil { result = await deliver(intent) }
        marker.cancel()
        guard !isStopped, let result else { return }
        settle(id, result)
    }

    private func markWaiting(_ id: UUID) {
        guard intents.contains(where: { $0.id == id && $0.isOpen }) else { return }
        waitingIds.insert(id)
    }

    private func deliver(_ intent: MVMailIntent) async -> MVIntentDelivery {
        let transport = transport
        let timeout = timing.requestTimeout
        do {
            switch intent.delivery {
            case .message:
                guard let messageId = intent.messageIds.first,
                    let action = MVMessageAction(rawValue: intent.action.rawValue)
                else { return .refused("Nothing to send") }
                let response = try await transport.deliverMessageAction(
                    messageId: messageId, action: action, targetFolderId: intent.targetFolderId,
                    expectedFolderId: intent.expectedFolderIds?[messageId], idempotencyKey: intent.id,
                    timeout: timeout)
                guard response.success else { return .refused(response.message ?? "The server did not apply it") }
                guard response.applied else { return .notApplied }
                return .delivered(
                    affectedCount: nil, sources: [], filed: response.folderId.map { [messageId: $0] } ?? [:])
            case .bulk(let expandThreads):
                let request = BulkActionRequest(
                    action: intent.action, targetFolderId: intent.targetFolderId, ids: intent.messageIds,
                    expandThreads: expandThreads, idempotencyKey: intent.id,
                    expectedFolderIds: intent.expectedFolderIds,
                    expandThreadsThrough: expandThreads ? intent.seenThrough : nil)
                return Self.delivered(
                    try await transport.deliverBulkAction(
                        accountId: intent.accountId, request: request, timeout: timeout), for: intent)
            case .conversationRead:
                guard let unread = try await resolveConversation(intent) else { return .refused("Nothing to send") }
                guard !unread.isEmpty else { return .delivered(affectedCount: 0, sources: []) }
                let request = BulkActionRequest(action: .markRead, ids: unread, idempotencyKey: intent.id)
                return Self.delivered(
                    try await transport.deliverBulkAction(
                        accountId: intent.accountId, request: request, timeout: timeout), for: intent)
            }
        } catch {
            return MVIntentDelivery.classify(error)
        }
    }

    /// A conversation read's unread messages, resolved once and kept. A message a later intent
    /// names is left out: marked unread since, say, it stays that way.
    private func resolveConversation(_ intent: MVMailIntent) async throws -> [UUID]? {
        if let resolved = intent.resolvedMessageIds { return resolved }
        guard case .conversationRead(let folderIds) = intent.delivery, let messageId = intent.messageIds.first else {
            return nil
        }
        let thread = try await transport.fetchConversation(messageId: messageId, timeout: timing.requestTimeout)
        guard let index = intents.firstIndex(where: { $0.id == intent.id }) else { return nil }
        let later = Set(intents[(index + 1)...].flatMap(\.messageIds))
        let scoped = Set(folderIds)
        let unread = thread.messages.filter { scoped.contains($0.folderId) && !$0.isSeen && !later.contains($0.id) }
            .map(\.id)
        intents[index].resolvedMessageIds = unread
        changed()
        return unread
    }

    /// For an intent that may already have been applied: done when every message already shows
    /// it, `nil` (send it) otherwise, or the lookup's own failure.
    private func reconcile(_ intent: MVMailIntent) async -> MVIntentDelivery? {
        let ids: [UUID]
        if case .conversationRead = intent.delivery {
            guard let resolved = intent.resolvedMessageIds else { return nil }
            ids = resolved
        } else {
            ids = intent.messageIds
        }
        guard ids.count <= timing.reconcileLimit else { return nil }
        let transport = transport
        let timeout = timing.requestTimeout
        do {
            for id in ids {
                let state = try await transport.fetchMessageState(
                    messageId: id, includeFlags: !intent.leavesFolder, timeout: timeout)
                guard Self.shows(intent, on: id, state) else { return nil }
            }
            return .delivered(affectedCount: nil, sources: [])
        } catch {
            switch MVIntentDelivery.classify(error) {
            case .hold(let reason): return .hold(reason)
            case .retry(let reason, _), .refused(let reason): return .retry(reason, mayHaveLanded: true)
            case .delivered, .gone, .notApplied: return nil
            }
        }
    }

    /// Whether `state` already carries what `intent` does to message `id` (`nil` state: gone).
    static func shows(_ intent: MVMailIntent, on id: UUID, _ state: MVMessageState?) -> Bool {
        guard let state else { return true }
        switch intent.action {
        case .expunge: return false
        case .move:
            return intent.targetFolderId == state.folderId
        case .archive, .trash, .spam, .notSpam:
            guard let origin = intent.originFolderIds[id] else { return false }
            return state.folderId != origin
        case .markRead: return state.isSeen == true
        case .markUnread: return state.isSeen == false
        case .flag: return state.isFlagged == true
        case .unflag: return state.isFlagged == false
        }
    }

    private static func delivered(_ response: BulkActionResponse, for intent: MVMailIntent) -> MVIntentDelivery {
        guard response.success else {
            let errors = response.errors.joined(separator: "; ")
            return .refused(errors.isEmpty ? "The server did not apply it" : errors)
        }
        let skipped = Set(response.skippedIds)
        if !skipped.isEmpty, response.affectedCount == 0, Set(intent.messageIds).isSubset(of: skipped) {
            return .notApplied
        }
        var filed: [UUID: UUID] = [:]
        if let target = response.targetFolderId {
            let moved = response.sources.isEmpty ? intent.messageIds : response.sources.map(\.id)
            for id in moved where !skipped.contains(id) { filed[id] = target }
        }
        return .delivered(affectedCount: response.affectedCount, sources: response.sources, filed: filed)
    }

    private func settle(_ id: UUID, _ result: MVIntentDelivery) {
        guard let index = intents.firstIndex(where: { $0.id == id }) else { return }
        switch result {
        case .delivered(let affected, let sources, let filed):
            sequence += 1
            intents[index].state = .done
            intents[index].settledSequence = sequence
            intents[index].settledAt = clock.now
            intents[index].movedSources = sources
            intents[index].filedFolderIds = filed
            intents[index].lastError = nil
            intents[index].mayHaveLanded = false
            waitingIds.remove(id)
            let intent = intents[index]
            if intent.undoRequested {
                intents[index].undoRequested = false
                appendReversal(of: intents[index])
            }
            changed()
            notifySettled([intent])
            finish(id, intent.undoRequested ? .cancelled : .done(affectedCount: affected, sources: sources))
            scheduleRetirement()
        case .gone, .notApplied:
            sequence += 1
            let intent = intents.remove(at: index)
            waitingIds.remove(id)
            changed()
            notifySettled([intent])
            if result == .notApplied, intent.undoes != nil {
                toasts?.show(MVToast(variant: .info, message: "Nothing to undo — the message has moved since"))
            }
            finish(id, result == .gone ? .gone : .notApplied)
        case .retry(let reason, let mayHaveLanded):
            intents[index].lastError = reason
            intents[index].mayHaveLanded = intents[index].mayHaveLanded || mayHaveLanded
            if intents[index].undoRequested {
                intents[index].state = .pending
                replaceWithReversal(id)
                changed()
            } else if intents[index].attempts >= timing.maxAttempts {
                fail(index, reason: "Still failing after \(intents[index].attempts) attempts: \(reason)")
            } else {
                intents[index].state = .pending
                let exponent = Double(max(intents[index].attempts - 1, 0))
                let delay = min(timing.backoffBase * pow(2, exponent), timing.backoffCap)
                intents[index].nextAttemptAt = clock.now.addingTimeInterval(delay)
                waitingIds.insert(id)
                changed()
            }
        case .hold(let reason):
            intents[index].state = .pending
            intents[index].attempts = max(intents[index].attempts - 1, 0)
            intents[index].lastError = reason
            waitingIds.insert(id)
            isHeld = true
            if intents[index].undoRequested { replaceWithReversal(id) }
            changed()
        case .refused(let reason):
            if intents[index].undoRequested && !intents[index].mayHaveLanded {
                intents.remove(at: index)
                waitingIds.remove(id)
                changed()
                finish(id, .cancelled)
            } else if intents[index].undoRequested {
                intents[index].state = .pending
                replaceWithReversal(id)
                changed()
            } else {
                fail(index, reason: reason)
            }
        }
    }

    private func fail(_ index: Int, reason: String) {
        sequence += 1
        intents[index].state = .failed
        intents[index].settledSequence = sequence
        intents[index].settledAt = clock.now
        intents[index].lastError = reason
        let intent = intents[index]
        waitingIds.remove(intent.id)
        changed()
        showFailure(intent, reason: reason)
        finish(intent.id, .failed(reason))
        scheduleRetirement()
    }

    private func finish(_ id: UUID, _ outcome: MVIntentOutcome) {
        callbacks.removeValue(forKey: id)?(outcome)
    }

    private func notifySettled(_ settled: [MVMailIntent]) {
        for observer in liveObservers { observer.intentsDidSettle(settled) }
    }

    private func showFailure(_ intent: MVMailIntent, reason: String) {
        let message =
            intent.undoes != nil ? "Could not undo: \(reason)" : "Could not \(intent.action.phrase): \(reason)"
        let id = intent.id
        toasts?.show(
            MVToast(
                variant: .error, message: message, duration: 0, actionTitle: "Retry",
                action: { [weak self] in Task { @MainActor in self?.retry([id]) } }))
    }

    // MARK: - Undo

    /// Removes an intent that may have reached the server and puts its reversal in its place.
    private func replaceWithReversal(_ id: UUID) {
        guard let index = intents.firstIndex(where: { $0.id == id }) else { return }
        let intent = intents.remove(at: index)
        waitingIds.remove(id)
        appendReversal(of: intent)
        finish(id, .cancelled)
    }

    private func appendReversal(of intent: MVMailIntent) {
        for reversal in Self.reversal(of: intent) {
            intents.append(
                MVMailIntent(request: reversal, id: UUID(), undoes: intent.id, createdAt: clock.now))
            startWorker(reversal.accountId)
        }
    }

    /// Moves back to each message's own origin folder — one intent per folder, expecting each
    /// message where the server said it filed it, so one filed elsewhere since stays there — or
    /// read and star state flipped back. Expunge and a conversation read have nothing to reverse.
    private static func reversal(of intent: MVMailIntent) -> [MVIntentRequest] {
        if let inverse = intent.action.inverse {
            if case .conversationRead = intent.delivery { return [] }
            return [
                MVIntentRequest(
                    accountId: intent.accountId, action: inverse, messageIds: intent.messageIds,
                    delivery: intent.delivery)
            ]
        }
        guard intent.action != .expunge else { return [] }
        let moved =
            intent.movedSources.isEmpty
            ? intent.messageIds.compactMap { id in intent.originFolderIds[id].map { (id, $0) } }
            : intent.movedSources.map { ($0.id, $0.folderId) }
        var byFolder: [UUID: [UUID]] = [:]
        for (messageId, folderId) in moved { byFolder[folderId, default: []].append(messageId) }
        return byFolder.keys.sorted(by: { $0.uuidString < $1.uuidString }).map { folderId in
            let ids = byFolder[folderId] ?? []
            return MVIntentRequest(
                accountId: intent.accountId, action: .move, targetFolderId: folderId, messageIds: ids,
                delivery: ids.count == 1 ? .message : .bulk(expandThreads: false),
                originFolderIds: intent.filedFolderIds.filter { ids.contains($0.key) },
                snapshots: intent.snapshots.filter { ids.contains($0.id) })
        }
    }

    // MARK: - Retirement

    private func scheduleRetirement() {
        retirementTask?.cancel()
        guard !isStopped else { return }
        guard let next = intents.compactMap(retirementDeadline).min() else { return }
        let clock = clock
        let delay = max(next.timeIntervalSince(clock.now), 0)
        retirementTask = Task { [weak self] in
            guard (try? await clock.sleep(for: delay)) != nil else { return }
            self?.retireDue()
        }
    }

    private func retirementDeadline(_ intent: MVMailIntent) -> Date? {
        guard let settledAt = intent.settledAt else { return nil }
        switch intent.state {
        case .done: return settledAt.addingTimeInterval(timing.doneRetention)
        case .failed: return settledAt.addingTimeInterval(timing.failedRetention)
        case .pending, .sending: return nil
        }
    }

    private func retireDue() {
        let now = clock.now
        let due = intents.filter { retirementDeadline($0).map { $0 <= now } ?? false }
        if !due.isEmpty {
            let done = due.filter { $0.state == .done }
            if !done.isEmpty {
                for observer in liveObservers { observer.intentsWillRetire(done) }
            }
            let ids = Set(due.map(\.id))
            intents.removeAll { ids.contains($0.id) }
            changed()
        }
        scheduleRetirement()
    }

    /// Every change goes to disk — never once stopped, when another ledger may own the file.
    private func changed() {
        guard !isStopped else { return }
        persistence.save(intents)
        if !hasOpenIntents { resumeIdleWaiters() }
    }

    private func resumeIdleWaiters() {
        let waiters = idleWaiters
        idleWaiters = []
        for waiter in waiters { waiter.resume() }
    }
}
