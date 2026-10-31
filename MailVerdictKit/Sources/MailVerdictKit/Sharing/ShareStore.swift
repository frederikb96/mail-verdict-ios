import Foundation
import Observation

/// Remembers that a send started and has not ended, across processes.
///
/// iOS can end an extension without a word, and then no screen of its own can say so. The next
/// share reads the mark left behind, so a share that died is reported rather than forgotten.
public struct ShareAttemptMark: Sendable {
    public let isSet: @Sendable () -> Bool
    public let set: @Sendable (Bool) -> Void

    public init(isSet: @escaping @Sendable () -> Bool, set: @escaping @Sendable (Bool) -> Void) {
        self.isSet = isSet
        self.set = set
    }
}

/// The account a draft was last saved in, so it is offered first next time.
public struct ShareAccountMemory: Sendable {
    public let read: @Sendable () -> UUID?
    public let write: @Sendable (UUID) -> Void

    public init(read: @escaping @Sendable () -> UUID?, write: @escaping @Sendable (UUID) -> Void) {
        self.read = read
        self.write = write
    }
}

/// Everything the share sheet shows and does, from the accounts it offers to the last upload.
@Observable
@MainActor
public final class ShareStore {

    public enum Phase: Equatable, Sendable {
        case choosing
        case sending(ShareDestination, done: Int, total: Int)
        case sent(ShareDestination)
        /// Some files may have arrived already. Sending again resumes with the rest.
        case failed(ShareDestination, message: String)
    }

    public private(set) var phase: Phase = .choosing
    public private(set) var accounts: [AccountResponse] = []
    public private(set) var accountsError: String?
    public private(set) var accountsLoaded = false

    public let items: [ShareItem]
    /// Why some of what was shared is not in `items`, or `nil` when all of it is.
    public let refusal: String?
    /// The previous share was ended by the system partway through its send.
    public let previousAttemptDied: Bool

    private let backend: any ShareBackend
    private let attemptMark: ShareAttemptMark
    private let accountMemory: ShareAccountMemory
    private var deliveredIds: Set<String> = []
    /// One key per share, so a draft whose answer was lost is the same row when sent again.
    private let draftKey = UUID()

    public init(
        items: [ShareItem], refusal: String?, backend: any ShareBackend, attemptMark: ShareAttemptMark,
        accountMemory: ShareAccountMemory
    ) {
        self.items = items
        self.refusal = refusal
        self.backend = backend
        self.attemptMark = attemptMark
        self.accountMemory = accountMemory
        previousAttemptDied = attemptMark.isSet()
        attemptMark.set(false)
    }

    /// Why this selection cannot become a draft, or `nil` when it can.
    public var draftRefusal: String? {
        if items.count > ShareLimits.maxDraftFiles {
            return "A draft takes up to \(ShareLimits.maxDraftFiles) files."
        }
        let total = items.reduce(0) { $0 + $1.sizeBytes }
        if total > ShareLimits.maxDraftBytes {
            let limit = ShareLimits.maxDraftBytes / 1_048_576
            return
                "Together these are too large for a draft from here (\(limit) MB). Attach them in MailVerdict instead."
        }
        return nil
    }

    /// Active accounts only, the one used last first.
    public func loadAccounts() async {
        do {
            let found = try await backend.accountsToShareInto().filter(\.isActive)
            let last = accountMemory.read()
            accounts = found.sorted { ($0.id == last ? 0 : 1) < ($1.id == last ? 0 : 1) }
            accountsError = nil
        } catch {
            accountsError = Self.message(for: error)
        }
        accountsLoaded = true
    }

    /// Sends everything to `destination`. A retry after a failure sends only what is missing.
    public func send(to destination: ShareDestination) async {
        switch phase {
        case .choosing, .failed: break
        case .sending, .sent: return
        }
        attemptMark.set(true)
        defer { attemptMark.set(false) }
        switch destination {
        case .orders: await sendToOrders()
        case .draft(let accountId, _): await sendDraft(accountId: accountId, destination: destination)
        }
    }

    /// One file at a time. A file the server will not take (type, size) is reported at the end
    /// and the rest still go; a refused credential or a lost connection stops the run, since the
    /// next file would meet the same thing.
    private func sendToOrders() async {
        let destination = ShareDestination.orders
        var failures: [String] = []
        for (index, item) in items.enumerated() {
            phase = .sending(destination, done: index, total: items.count)
            guard !deliveredIds.contains(item.id) else { continue }
            do {
                let file = try await Self.prepare(item, policy: .orders)
                try await backend.addToOrders(file)
                deliveredIds.insert(item.id)
            } catch {
                if Self.endsTheRun(error) {
                    phase = .failed(destination, message: Self.message(for: error))
                    return
                }
                failures.append("\(item.name): \(Self.message(for: error))")
            }
        }
        phase = failures.isEmpty ? .sent(destination) : .failed(destination, message: failures.joined(separator: "\n"))
    }

    private func sendDraft(accountId: UUID, destination: ShareDestination) async {
        if let refusal = draftRefusal {
            phase = .failed(destination, message: refusal)
            return
        }
        phase = .sending(destination, done: 0, total: items.count)
        do {
            var uploads: [MVOutboxAttachmentUpload] = []
            for item in items {
                let file = try await Self.prepare(item, policy: .draft)
                uploads.append(
                    MVOutboxAttachmentUpload(filename: file.filename, contentType: file.contentType, data: file.data))
            }
            let request = OutboxCreateRequest(
                accountId: accountId, kind: .draft, to: [], subject: Self.draftSubject(items.map(\.name)),
                idempotencyKey: draftKey)
            try await backend.saveDraft(request, uploads: uploads)
            accountMemory.write(accountId)
            phase = .sent(destination)
        } catch {
            phase = .failed(destination, message: Self.message(for: error))
        }
    }

    /// The draft's subject, so it can be told apart in the Drafts folder: the file's name, or the
    /// first one's with a count.
    static func draftSubject(_ names: [String]) -> String? {
        guard let first = names.first else { return nil }
        return names.count == 1 ? first : "\(first) and \(names.count - 1) more"
    }

    private static func prepare(_ item: ShareItem, policy: ShareFitPolicy) async throws -> ShareFile {
        let prepare = item.prepare
        let file = try await Task.detached { try prepare(policy) }.value
        guard file.data.count <= ShareLimits.maxFileBytes else { throw ShareError.tooLarge(name: item.name) }
        return file
    }

    private static func endsTheRun(_ error: Error) -> Bool {
        guard let mvError = error as? MVError else { return false }
        switch mvError {
        case .transport, .proxyRequiresBrowserLogin: return true
        case .detail, .http, .decoding: return mvError.isAuthenticationFailure
        }
    }

    static func message(for error: Error) -> String {
        if let shareError = error as? ShareError {
            switch shareError {
            case .tooLarge: return "This file is larger than the server takes."
            }
        }
        guard let mvError = error as? MVError else { return error.localizedDescription }
        if mvError.isAuthenticationFailure || mvError == .proxyRequiresBrowserLogin {
            return "MailVerdict could not sign in. Open the app, sign in, and share again."
        }
        switch mvError.statusCode {
        case 413: return "This file is larger than the server takes."
        default: return mvError.userMessage
        }
    }
}
