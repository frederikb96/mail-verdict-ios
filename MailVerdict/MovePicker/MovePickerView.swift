import MailVerdictKit
import SwiftUI

/// Move to… for one message, presentable as a sheet from anywhere that has a message's account
/// and folder — the reader's Options "Move to…" among them. Hands back the chosen folder's id.
struct MovePickerView: View {
    let accountId: UUID
    let excludingFolderId: UUID?
    let onPick: (UUID) -> Void

    @Environment(\.mvApiClient) private var apiClient

    var body: some View {
        if let apiClient {
            MovePickerSheet(
                source: .folders(accountId: accountId, excludingFolderId: excludingFolderId), backend: apiClient
            ) { target in
                if let folderId = target.folderId(forAccount: accountId) { onPick(folderId) }
            }
        } else {
            ContentUnavailableView("Folders Unavailable", systemImage: MVSymbols.moveTo)
        }
    }
}

private struct MVApiClientKey: EnvironmentKey {
    static let defaultValue: MVApiClient? = nil
}

extension EnvironmentValues {
    /// The connection's API client, for a view presented somewhere its caller has no connection
    /// to hand over.
    var mvApiClient: MVApiClient? {
        get { self[MVApiClientKey.self] }
        set { self[MVApiClientKey.self] = newValue }
    }
}
