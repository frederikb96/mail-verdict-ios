import Foundation
import Observation

/// Something holding server data the ledger's intents are projected over — a list, the reader.
@MainActor
public protocol MVIntentObserver: AnyObject {
    /// `MVIntentLedger.sequence` when the oldest data this holds was read; `Int.max` when it holds
    /// none.
    var intentBaseSequence: Int { get }
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
/// taken, and never an intent ahead of an earlier one naming the same message, so a mark-read
/// and an archive of one message always arrive in that order. A request that gets no answer, a
/// timeout, a 429 or a 5xx is retried with backoff; while the device is offline nothing is sent,
/// and everything goes the moment it is back. Any other 4xx refuses the intent for good; a 404
/// means the message is gone and the intent simply retires.
@Observable
@MainActor
public final class MVIntentLedger {

    public struct Timing: Sendable {
        /// Replaces the session's minute-long default for every delivery request.
        public var requestTimeout: TimeInterval = 20
        /// How long a request may be out before its rows say they are waiting.
        public var waitingAfter: TimeInterval = 0.8
        public var backoffBase: TimeInterval = 1
        public var backoffCap: TimeInterval = 60
        /// How long a done intent stays. It stops applying the moment data read after it lands —
        /// that read is the server agreeing — but stays this long to be undone, and so that a read
        /// begun before it settled has landed or failed before its effect is folded in for good.
        public var doneRetention: TimeInterval = 90
        /// How long a refused intent keeps marking its rows.
        public var failedRetention: TimeInterval = 300

        public init() {}
    }

    /// Creation order. Open intents first applied, done ones kept until retired.
    public private(set) var intents: [MVMailIntent] = []
    /// Bumped whenever an intent settles. Data records it when its read begins
    /// (`MVIntentProjection.applies`).
    public private(set) var sequence = 0
    /// Open intents that have been waiting long enough to say so.
    public private(set) var waitingIds: Set<UUID> = []

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
    @ObservationIgnored private var undoWhenSettled: Set<UUID> = []
    @ObservationIgnored private var callbacks: [UUID: @MainActor (MVIntentOutcome) -> Void] = [:]
    @ObservationIgnored private var isStopped = false

    private final class WeakObserver {
        weak var observer: (any MVIntentObserver)?
        init(_ observer: any MVIntentObserver) { self.observer = observer }
    }

    /// Loads what the last launch left: a request that was out is sent again (its idempotency key
    /// makes that safe), and a done one is dropped, since every read from now on already has it.
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
            case .sending: intent.state = .pending
            case .pending, .failed: break
            }
            return intent
        }
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

    /// Messages an intent has taken out of their folder and no later one has moved back — the
    /// reader skips them when paging.
    public var hiddenMessageIds: Set<UUID> {
        var hidden: Set<UUID> = []
        for intent in intents where intent.leavesFolder && intent.state != .failed {
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
            case .pending, .sending: if waitingIds.contains(intent.id) { state = .waiting }
            case .done: break
            }
        }
        return state
    }

    /// "3 actions waiting for the network", or `nil` with nothing waiting.
    public var waitingSummary: String? {
        let count = intents.filter { $0.isOpen && waitingIds.contains($0.id) }.count
        guard count > 0 else { return nil }
        return "\(count) \(count == 1 ? "action" : "actions") waiting for the network"
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
        var request = request
        if request.snapshots.isEmpty {
            let wanted = Set(request.messageIds)
            request.snapshots = liveObservers.lazy.map { $0.intentSnapshots(for: wanted) }.first { !$0.isEmpty } ?? []
        }
        append(MVMailIntent(request: request, id: id, undoes: nil, createdAt: clock.now), onSettled: onSettled)
        if let undoToast {
            toasts?.show(
                MVToast(
                    variant: .success, message: undoToast, duration: 6, actionTitle: "Undo",
                    action: { [weak self] in Task { @MainActor in self?.undo([id]) } }))
        }
        return id
    }

    /// Undoes intents: one never sent is simply dropped, one already done is reversed by a new
    /// intent moving each message back (or flipping read and star back), one still out is
    /// reversed once it lands.
    public func undo(_ ids: [UUID]) {
        var reverse: [MVMailIntent] = []
        for id in ids {
            guard let index = intents.firstIndex(where: { $0.id == id }) else { continue }
            switch intents[index].state {
            case .pending:
                let intent = intents.remove(at: index)
                waitingIds.remove(id)
                finish(intent.id, .cancelled)
            case .sending:
                undoWhenSettled.insert(id)
            case .done:
                reverse.append(intents[index])
            case .failed:
                intents.remove(at: index)
            }
        }
        for request in Self.reversal(of: reverse) {
            append(MVMailIntent(request: request.request, id: UUID(), undoes: request.undoes, createdAt: clock.now))
        }
        save()
    }

    /// Sends a refused intent again from scratch.
    public func retry(_ id: UUID) {
        guard let index = intents.firstIndex(where: { $0.id == id }), intents[index].state == .failed else { return }
        intents[index].state = .pending
        intents[index].attempts = 0
        intents[index].nextAttemptAt = nil
        intents[index].lastError = nil
        intents[index].settledSequence = nil
        intents[index].settledAt = nil
        save()
        startWorker(intents[index].accountId)
    }

    /// Back in the foreground or back online: whatever is waiting on a backoff goes now.
    public func resume() {
        guard !isStopped else { return }
        for index in intents.indices where intents[index].state == .pending {
            intents[index].nextAttemptAt = nil
        }
        for accountId in Set(intents.filter(\.isOpen).map(\.accountId)) { startWorker(accountId) }
    }

    /// Ends delivery for good — the connection this ledger belongs to is going away. Open intents
    /// stay persisted for the next ledger on the same server.
    public func stop() {
        isStopped = true
        for task in workers.values { task.cancel() }
        for task in sleepers.values { task.cancel() }
        retirementTask?.cancel()
        workers = [:]
        sleepers = [:]
    }

    // MARK: - Delivery

    private func append(_ intent: MVMailIntent, onSettled: (@MainActor (MVIntentOutcome) -> Void)? = nil) {
        intents.append(intent)
        if let onSettled { callbacks[intent.id] = onSettled }
        save()
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
        /// `nil`: until woken — the network returning, or a new intent.
        case wait(TimeInterval?)
    }

    private func nextStep(for accountId: UUID) -> Step? {
        guard !isStopped else { return nil }
        let open = intents.filter { $0.accountId == accountId && $0.isOpen }
        guard !open.isEmpty else { return nil }
        guard connectivity.isOnline else {
            waitingIds.formUnion(open.map(\.id))
            return .wait(nil)
        }
        let now = clock.now
        var blocked: Set<UUID> = []
        var earliest: Date?
        for intent in open {
            if intent.state == .pending, blocked.isDisjoint(with: intent.messageIds) {
                guard let due = intent.nextAttemptAt, due > now else { return .send(intent.id) }
                earliest = min(earliest ?? due, due)
            }
            blocked.formUnion(intent.messageIds)
        }
        return .wait(earliest.map { $0.timeIntervalSince(now) })
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
        save()

        let clock = clock
        let waitingAfter = timing.waitingAfter
        let marker = Task { [weak self] in
            guard (try? await clock.sleep(for: waitingAfter)) != nil else { return }
            self?.markWaiting(id)
        }
        let result = await deliver(intent)
        marker.cancel()
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
                try await transport.deliverMessageAction(
                    messageId: messageId, action: action, targetFolderId: intent.targetFolderId, timeout: timeout)
                return .delivered(affectedCount: nil, sources: [])
            case .bulk(let expandThreads):
                let request = BulkActionRequest(
                    action: intent.action, targetFolderId: intent.targetFolderId, ids: intent.messageIds,
                    expandThreads: expandThreads)
                return Self.delivered(
                    try await transport.deliverBulkAction(
                        accountId: intent.accountId, request: request, timeout: timeout))
            case .conversationRead(let folderIds):
                guard let messageId = intent.messageIds.first else { return .refused("Nothing to send") }
                let thread = try await transport.fetchThread(messageId: messageId)
                let scoped = Set(folderIds)
                let unread = thread.messages.filter { scoped.contains($0.folderId) && !$0.isSeen }.map(\.id)
                guard !unread.isEmpty else { return .delivered(affectedCount: 0, sources: []) }
                let request = BulkActionRequest(action: .markRead, ids: unread)
                return Self.delivered(
                    try await transport.deliverBulkAction(
                        accountId: intent.accountId, request: request, timeout: timeout))
            }
        } catch {
            return MVIntentDelivery.classify(error)
        }
    }

    private static func delivered(_ response: BulkActionResponse) -> MVIntentDelivery {
        guard response.success else {
            let errors = response.errors.joined(separator: "; ")
            return .refused(errors.isEmpty ? "The server did not apply it" : errors)
        }
        return .delivered(affectedCount: response.affectedCount, sources: response.sources)
    }

    private func settle(_ id: UUID, _ result: MVIntentDelivery) {
        guard let index = intents.firstIndex(where: { $0.id == id }) else { return }
        switch result {
        case .delivered(let affected, let sources):
            sequence += 1
            intents[index].state = .done
            intents[index].settledSequence = sequence
            intents[index].settledAt = clock.now
            intents[index].movedSources = sources
            intents[index].lastError = nil
            waitingIds.remove(id)
            let intent = intents[index]
            save()
            notifySettled([intent])
            finish(id, .done(affectedCount: affected, sources: sources))
            if undoWhenSettled.remove(id) != nil { undo([id]) }
            scheduleRetirement()
        case .gone:
            sequence += 1
            let intent = intents.remove(at: index)
            waitingIds.remove(id)
            undoWhenSettled.remove(id)
            save()
            notifySettled([intent])
            finish(id, .gone)
        case .retry(let reason):
            intents[index].state = .pending
            intents[index].lastError = reason
            let delay = min(timing.backoffBase * pow(2, Double(max(intents[index].attempts - 1, 0))), timing.backoffCap)
            intents[index].nextAttemptAt = clock.now.addingTimeInterval(delay)
            waitingIds.insert(id)
            save()
        case .refused(let reason):
            sequence += 1
            intents[index].state = .failed
            intents[index].settledSequence = sequence
            intents[index].settledAt = clock.now
            intents[index].lastError = reason
            waitingIds.remove(id)
            undoWhenSettled.remove(id)
            let intent = intents[index]
            save()
            showFailure(intent, reason: reason)
            finish(id, .failed(reason))
            scheduleRetirement()
        }
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
                action: { [weak self] in Task { @MainActor in self?.retry(id) } }))
    }

    // MARK: - Undo

    private struct Reversal {
        let request: MVIntentRequest
        let undoes: UUID
    }

    /// Moves back to each message's own origin folder — one intent per account and folder — and
    /// read or star state flipped back. Expunge and a conversation read have nothing to reverse.
    private static func reversal(of intents: [MVMailIntent]) -> [Reversal] {
        var result: [Reversal] = []
        for intent in intents {
            if let inverse = intent.action.inverse {
                if case .conversationRead = intent.delivery { continue }
                result.append(
                    Reversal(
                        request: MVIntentRequest(
                            accountId: intent.accountId, action: inverse, messageIds: intent.messageIds,
                            delivery: intent.delivery), undoes: intent.id))
                continue
            }
            guard intent.action != .expunge else { continue }
            let moved =
                intent.movedSources.isEmpty
                ? intent.messageIds.compactMap { id in intent.originFolderIds[id].map { (id, $0) } }
                : intent.movedSources.map { ($0.id, $0.folderId) }
            var byFolder: [UUID: [UUID]] = [:]
            for (messageId, folderId) in moved { byFolder[folderId, default: []].append(messageId) }
            for folderId in byFolder.keys.sorted(by: { $0.uuidString < $1.uuidString }) {
                let ids = byFolder[folderId] ?? []
                let snapshots = intent.snapshots.filter { ids.contains($0.id) }
                result.append(
                    Reversal(
                        request: MVIntentRequest(
                            accountId: intent.accountId, action: .move, targetFolderId: folderId, messageIds: ids,
                            delivery: ids.count == 1 ? .message : .bulk(expandThreads: false),
                            originFolderIds: Dictionary(uniqueKeysWithValues: ids.map { ($0, folderId) }),
                            snapshots: snapshots), undoes: intent.id))
            }
        }
        return result
    }

    // MARK: - Retirement

    private func scheduleRetirement() {
        retirementTask?.cancel()
        guard !isStopped else { return }
        let deadlines = intents.compactMap { intent -> Date? in
            guard let settledAt = intent.settledAt else { return nil }
            switch intent.state {
            case .done: return settledAt.addingTimeInterval(timing.doneRetention)
            case .failed: return settledAt.addingTimeInterval(timing.failedRetention)
            case .pending, .sending: return nil
            }
        }
        guard let next = deadlines.min() else { return }
        let clock = clock
        let delay = max(next.timeIntervalSince(clock.now), 0)
        retirementTask = Task { [weak self] in
            guard (try? await clock.sleep(for: delay)) != nil else { return }
            self?.retireDue()
        }
    }

    private func retireDue() {
        let now = clock.now
        let due = intents.filter { intent in
            guard let settledAt = intent.settledAt else { return false }
            switch intent.state {
            case .done: return settledAt.addingTimeInterval(timing.doneRetention) <= now
            case .failed: return settledAt.addingTimeInterval(timing.failedRetention) <= now
            case .pending, .sending: return false
            }
        }
        if !due.isEmpty {
            let done = due.filter { $0.state == .done }
            if !done.isEmpty {
                for observer in liveObservers { observer.intentsWillRetire(done) }
            }
            let ids = Set(due.map(\.id))
            intents.removeAll { ids.contains($0.id) }
            save()
        }
        scheduleRetirement()
    }

    private func save() {
        persistence.save(intents)
    }
}
