import Foundation

/// Remembers the screen brightness a person had while a code is shown at full brightness, so
/// leaving restores exactly that -- once. Showing twice without leaving (a scene returning to
/// active while the code is still up) must not record the already-raised value as the one to go
/// back to, and leaving twice (disappearing, then the scene going inactive) must not restore twice.
public struct MVBrightnessHold: Sendable, Equatable {
    public private(set) var saved: Double?

    public init() {}

    /// The brightness to set, or `nil` when already raised.
    public mutating func engage(current: Double) -> Double? {
        guard saved == nil else { return nil }
        saved = current
        return 1.0
    }

    /// The brightness to restore, or `nil` when nothing is held.
    public mutating func release() -> Double? {
        defer { saved = nil }
        return saved
    }

    public var isEngaged: Bool { saved != nil }
}
