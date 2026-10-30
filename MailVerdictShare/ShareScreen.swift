import MailVerdictKit
import SwiftUI

/// Pick Orders or an account for a new draft, then watch the files go.
struct ShareScreen: View {
    let providers: [NSItemProvider]
    let close: () -> Void

    @State private var store: ShareStore?
    @State private var notConnected = false

    var body: some View {
        NavigationStack {
            Group {
                if let store {
                    ShareFlowView(store: store, close: close)
                } else if notConnected {
                    ContentUnavailableView(
                        "Not signed in", systemImage: "person.crop.circle.badge.exclamationmark",
                        description: Text("Open MailVerdict and sign in, then share again."))
                } else {
                    ProgressView("Reading what you shared")
                }
            }
            .navigationTitle("MailVerdict")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", action: close)
                }
            }
        }
        .task {
            guard store == nil, !notConnected else { return }
            guard let client = Self.client() else {
                notConnected = true
                return
            }
            let loaded = await SharedItemLoader.load(providers)
            store = ShareStore(
                items: loaded.items, refusal: loaded.refusal, backend: client, attemptMark: .extensionDefaults,
                accountMemory: .extensionDefaults)
        }
    }

    /// The connection the app signed in with, read from the Keychain group both targets hold. Only
    /// read here: signing in, and signing out, belong to the app.
    private static func client() -> MVApiClient? {
        let credentials = MVKeychainCredentialStore()
        guard let url = credentials.readBackendURL(), let mode = credentials.read(),
            let factory = try? MVRequestFactory(baseURL: url, authProvider: { mode })
        else { return nil }
        return MVApiClient(requestFactory: factory)
    }
}

extension ShareAttemptMark {
    private static let key = "shareAttemptInProgress"

    static let extensionDefaults = ShareAttemptMark(
        isSet: { UserDefaults.standard.bool(forKey: key) },
        set: { UserDefaults.standard.set($0, forKey: key) })
}

extension ShareAccountMemory {
    private static let key = "lastDraftAccount"

    static let extensionDefaults = ShareAccountMemory(
        read: { UserDefaults.standard.string(forKey: key).flatMap(UUID.init(uuidString:)) },
        write: { UserDefaults.standard.set($0.uuidString, forKey: key) })
}

private struct ShareFlowView: View {
    let store: ShareStore
    let close: () -> Void

    var body: some View {
        switch store.phase {
        case .choosing:
            chooser
        case .sending(let destination, let done, let total):
            ProgressView(
                sendingTitle(destination, done: done, total: total), value: Double(done), total: Double(max(total, 1))
            )
            .padding()
        case .sent(let destination):
            ContentUnavailableView(
                "Done", systemImage: "checkmark.circle", description: Text(sentMessage(destination))
            )
            .task {
                try? await Task.sleep(for: .seconds(1.2))
                close()
            }
        case .failed(let destination, let message):
            ContentUnavailableView {
                Label("Not everything arrived", systemImage: "exclamationmark.triangle")
            } description: {
                Text(message)
            } actions: {
                Button("Try again") { Task { await store.send(to: destination) } }
            }
        }
    }

    private var chooser: some View {
        List {
            if store.previousAttemptDied {
                Section {
                    Label(
                        "The last share stopped before it finished, so some files may be missing.",
                        systemImage: "exclamationmark.triangle"
                    )
                    .font(.footnote)
                }
            }
            Section {
                ForEach(store.items) { item in
                    Label(item.name, systemImage: "doc").lineLimit(1).truncationMode(.middle)
                }
                if let refusal = store.refusal {
                    Text(refusal).font(.footnote).foregroundStyle(.secondary)
                }
            }
            if !store.items.isEmpty {
                ordersSection
                draftSection
            }
        }
        .task { await store.loadAccounts() }
    }

    private var ordersSection: some View {
        Section {
            Button {
                Task { await store.send(to: .orders) }
            } label: {
                Label("Add to Orders", systemImage: "ticket")
            }
        } footer: {
            Text("Reads the files and files them under an order or ticket.")
        }
    }

    private var draftSection: some View {
        Section {
            if let error = store.accountsError {
                Text(error).font(.footnote).foregroundStyle(.secondary)
            } else if !store.accountsLoaded {
                ProgressView()
            }
            ForEach(store.accounts) { account in
                Button {
                    Task { await store.send(to: .draft(accountId: account.id, accountName: account.name)) }
                } label: {
                    Label(Self.title(of: account), systemImage: "square.and.pencil")
                }
                .disabled(store.draftRefusal != nil)
            }
        } header: {
            Text("New mail in")
        } footer: {
            Text(store.draftRefusal ?? "Saves a draft with the files attached. Open it later from Drafts.")
        }
    }

    private static func title(of account: AccountResponse) -> String {
        guard let emoji = account.emoji, !emoji.isEmpty else { return account.name }
        return "\(emoji) \(account.name)"
    }

    private func sendingTitle(_ destination: ShareDestination, done: Int, total: Int) -> String {
        switch destination {
        case .orders: return "Adding \(min(done + 1, total)) of \(total)"
        case .draft: return "Saving the draft"
        }
    }

    private func sentMessage(_ destination: ShareDestination) -> String {
        switch destination {
        case .orders: return "Added to Orders & Tickets. It is being read now."
        case .draft(_, let accountName): return "Saved to Drafts in \(accountName)."
        }
    }
}
