import Foundation
import MailVerdictKit

/// What the composer shares with the rest of the app across one connection: the undo-send store
/// (the capsule shows it, the composer feeds it), the crash-recovery folder, and the composer
/// currently open, for the debug bridge.
@MainActor
final class ComposerServices {
    static let shared = ComposerServices()

    /// Set by `UndoSendCapsule` when the connected shell appears.
    var undoSend: UndoSendStore?
    weak var activeComposer: ComposerStore?
    let recovery: ComposeRecoveryStore

    private init() {
        let base =
            FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        recovery = ComposeRecoveryStore(directory: base.appendingPathComponent("compose-recovery", isDirectory: true))
    }
}
