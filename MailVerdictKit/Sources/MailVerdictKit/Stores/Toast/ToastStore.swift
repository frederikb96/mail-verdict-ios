import Foundation
import Observation

public enum MVToastVariant: Sendable, Equatable {
    case info, success, warning, error
}

/// One toast — `duration == 0` means persistent, dismissed only by its own ✕ or an explicit
/// `dismiss(id:)` call, matching the UX design's own rule. `action`/`actionTitle` are both `nil`
/// or both set; there is at most one action button.
public struct MVToast: Identifiable, Sendable {
    public let id: UUID
    public let variant: MVToastVariant
    public let message: String
    public let duration: TimeInterval
    public let actionTitle: String?
    public let action: (@Sendable () -> Void)?

    public init(
        id: UUID = UUID(), variant: MVToastVariant, message: String, duration: TimeInterval = 5,
        actionTitle: String? = nil, action: (@Sendable () -> Void)? = nil
    ) {
        self.id = id
        self.variant = variant
        self.message = message
        self.duration = duration
        self.actionTitle = actionTitle
        self.action = action
    }
}

/// The root toast host's state — one current toast at a time, the latest call replacing whatever
/// was showing. `Observation`, not `Combine`: part of the Swift toolchain rather than an Apple
/// SDK, so this compiles and is tested on Linux the same as every other store in this package.
@Observable
@MainActor
public final class MVToastStore {
    public private(set) var current: MVToast?

    private var dismissTask: Task<Void, Never>?

    public init() {}

    public func show(_ toast: MVToast) {
        dismissTask?.cancel()
        current = toast
        guard toast.duration > 0 else { return }

        let id = toast.id
        let nanoseconds = UInt64(toast.duration * 1_000_000_000)
        dismissTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: nanoseconds)
            guard !Task.isCancelled else { return }
            self?.dismiss(id: id)
        }
    }

    /// A no-op if a different (newer) toast is already showing — a delayed timer firing for a
    /// toast that was already replaced must never dismiss the one that replaced it.
    public func dismiss(id: UUID) {
        guard current?.id == id else { return }
        dismissTask?.cancel()
        dismissTask = nil
        current = nil
    }
}
