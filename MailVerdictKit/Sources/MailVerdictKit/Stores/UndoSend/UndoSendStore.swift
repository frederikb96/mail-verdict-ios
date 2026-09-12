import Foundation
import Observation

public struct UndoSendDependencies: Sendable {
    public var listPending: @Sendable () async throws -> [PendingSendResponse]
    public var cancel: @Sendable (UUID) async throws -> Void
    public var getAttachment:
        @Sendable (_ pendingSendId: UUID, _ attachmentId: UUID) async throws -> (
            data: Data, contentType: String?, suggestedFilename: String?
        )

    public init(
        listPending: @escaping @Sendable () async throws -> [PendingSendResponse],
        cancel: @escaping @Sendable (UUID) async throws -> Void,
        getAttachment:
            @escaping @Sendable (UUID, UUID) async throws -> (
                data: Data, contentType: String?, suggestedFilename: String?
            )
    ) {
        self.listPending = listPending
        self.cancel = cancel
        self.getAttachment = getAttachment
    }

    public static func live(client: MVApiClient) -> UndoSendDependencies {
        UndoSendDependencies(
            listPending: { try await client.listPendingSends() },
            cancel: { try await client.cancelPendingSend(id: $0) },
            getAttachment: { try await client.getPendingSendAttachment(pendingSendId: $0, attachmentId: $1) })
    }
}

/// What a cancelled send gives back to the composer that reopens it: the staged row, its files
/// sorted into chips and inline images, and the names of any that could not be fetched.
public struct UndoSendRestoration: Equatable, Sendable {
    public let row: PendingSendResponse
    public let attachments: [ComposeAttachment]
    public let inlineImages: [ComposeInlineImage]
    public let missing: [String]

    /// `fetched` is aligned with `row.attachments`. A file carrying a content id was a pasted
    /// image and goes back into the body; every other one becomes a chip again.
    public static func build(
        row: PendingSendResponse, fetched: [Result<(data: Data, contentType: String?), any Error>]
    ) -> UndoSendRestoration {
        var attachments: [ComposeAttachment] = []
        var images: [ComposeInlineImage] = []
        var missing: [String] = []
        for (index, summary) in row.attachments.enumerated() {
            let name = summary.filename ?? "attachment"
            guard index < fetched.count, case .success(let file) = fetched[index] else {
                missing.append(name)
                continue
            }
            let contentType = summary.contentType ?? file.contentType
            if let contentId = summary.contentId, !contentId.isEmpty {
                images.append(
                    ComposeInlineImage(contentId: contentId, filename: name, contentType: contentType, data: file.data))
            } else {
                attachments.append(ComposeAttachment(filename: name, contentType: contentType, data: file.data))
            }
        }
        return UndoSendRestoration(row: row, attachments: attachments, inlineImages: images, missing: missing)
    }
}

public enum UndoSendOutcome: Equatable, Sendable {
    /// Cancelled in time; present this intent to reopen the composer with everything restored.
    case restored(ComposeIntent)
    case tooLate
    case ignored
}

/// Sends held inside the server's undo window, for the undo-send capsule. Rows come from a
/// submit's own response and from `GET /outbox/pending` whenever the app looks again.
@Observable
@MainActor
public final class UndoSendStore {

    public private(set) var pending: [PendingSendResponse] = []
    public private(set) var cancelling: Set<UUID> = []
    private var restorations: [UUID: UndoSendRestoration] = [:]
    private let dependencies: UndoSendDependencies

    /// How long a row stays after its countdown reaches zero, while the server finishes sending
    /// it; past that it has either gone out or will show up again on the next refresh.
    public static let expiryGrace: TimeInterval = 2

    public init(dependencies: UndoSendDependencies) {
        self.dependencies = dependencies
    }

    public func refresh() async {
        guard let rows = try? await dependencies.listPending() else { return }
        pending = rows
    }

    public func add(_ row: PendingSendResponse) {
        pending.removeAll { $0.id == row.id }
        pending.append(row)
    }

    public func visibleRows(now: Date) -> [PendingSendResponse] {
        pending.filter { $0.sendAfter.addingTimeInterval(Self.expiryGrace) > now }.sorted {
            $0.sendAfter < $1.sendAfter
        }
    }

    public static func secondsRemaining(until sendAfter: Date, now: Date) -> Int {
        max(0, Int(sendAfter.timeIntervalSince(now).rounded(.up)))
    }

    /// Cancels the send, then fetches back every staged file. Any failure to cancel reads as too
    /// late — by then the message has usually left.
    public func undo(_ id: UUID) async -> UndoSendOutcome {
        guard let row = pending.first(where: { $0.id == id }), !cancelling.contains(id) else { return .ignored }
        cancelling.insert(id)
        defer { cancelling.remove(id) }
        do {
            try await dependencies.cancel(id)
        } catch {
            pending.removeAll { $0.id == id }
            return .tooLate
        }
        pending.removeAll { $0.id == id }

        var fetched: [Result<(data: Data, contentType: String?), any Error>] = []
        for attachment in row.attachments {
            do {
                let file = try await dependencies.getAttachment(id, attachment.id)
                fetched.append(.success((file.data, file.contentType)))
            } catch {
                fetched.append(.failure(error))
            }
        }
        restorations[id] = UndoSendRestoration.build(row: row, fetched: fetched)
        return .restored(ComposeIntent(kind: .undoRestore(pendingSendId: id)))
    }

    /// What the composer reopening a cancelled send starts from. Not consumed by reading: a view
    /// can be built more than once before it settles, and every build must find the same content.
    public func restoration(for id: UUID) -> UndoSendRestoration? {
        restorations[id]
    }

    /// Releases a restoration's files once the composer that used it has closed.
    public func forgetRestoration(for id: UUID) {
        restorations[id] = nil
    }
}
