/// What a one-time Keychain-group migration must do — expressed with no `Security` calls at
/// all, so the decision is tested on Linux; `PushKeychain.migrateFromLegacyGroupIfNeeded()` is
/// the only caller, and it performs what this describes.
public struct MVKeychainMigrationStep: Equatable, Sendable {
    public let serverOrigin: String

    public init(serverOrigin: String) {
        self.serverOrigin = serverOrigin
    }
}

public enum MVKeychainMigrationPlan {
    /// Every legacy-group origin not already present in the new group — each one needs its
    /// installation copied over and then removed from the legacy group. An origin already
    /// present in both is left alone, so re-running after a partial failure only redoes what
    /// is still outstanding rather than re-copying everything.
    public static func steps(legacyOrigins: [String], currentOrigins: [String]) -> [MVKeychainMigrationStep] {
        let current = Set(currentOrigins)
        return legacyOrigins.filter { !current.contains($0) }.map(MVKeychainMigrationStep.init)
    }
}
