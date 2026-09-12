import Observation

/// Which of the app's three connection states the shell is in.
public enum AppGate: Sendable, Equatable {
    /// No backend URL and token saved yet.
    case needsConfiguration
    /// A saved token was refused by the backend; `SignInView` shows why.
    case tokenRejected
    /// Connected — whatever screen comes next is not this type's concern.
    case ready
}

/// The gate in front of the app's navigation.
///
/// Kept as a value-holding observable rather than free functions on a view so that "where is the
/// user" is a question with one answer. `Observation` is part of the Swift toolchain rather than
/// an Apple SDK, so this compiles and is tested on Linux — the same reasoning that keeps every
/// other store in this package platform-agnostic.
///
/// Carries no navigation path yet: there are no destinations to push to. Whatever adds the first
/// screen is the place to grow one, alongside a `Route` enum for `.navigationDestination(for:)`
/// to switch over.
@Observable
public final class Router {
    public var gate: AppGate

    public init(gate: AppGate = .needsConfiguration) {
        self.gate = gate
    }
}
