import Foundation
import MailVerdictKit
import SwiftUI

/// One account's detail — status, the sync toggle, read-only server details, and the
/// destructive/editing actions. A direct port of the web's `AccountCard`, minus its collapsible
/// chrome: each section here is just part of the page.
struct AccountDetailScreen: View {
    let accountId: UUID
    let environment: AppEnvironment
    let connection: AppEnvironment.Connection

    @State private var store: MVAccountDetailStore?
    @State private var showingEditSheet = false
    @State private var confirmDelete = false
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        content
            .navigationTitle(store?.account?.name ?? "Account")
            .accessibilityIdentifier("account-detail-screen")
            #if DEBUG
                .screenshotReady(route: .account(accountId), environment: environment, connection: connection)
            #endif
            .sheet(isPresented: $showingEditSheet) {
                if let account = store?.account {
                    AccountFormView(mode: .edit(account)) { input in
                        try await store?.update(input)
                    }
                }
            }
            .confirmationDialog(
                "Delete \"\(store?.account?.name ?? "")\"?",
                isPresented: $confirmDelete, titleVisibility: .visible
            ) {
                Button("Delete Account", role: .destructive) { Task { await delete() } }
            } message: {
                Text(
                    "This removes the account and its entire locally mirrored mailbox. It cannot "
                        + "be undone. Nothing is touched on the mail server itself — re-adding the "
                        + "account re-syncs everything from scratch.")
            }
            .task {
                if store == nil { store = MVAccountDetailStore(accountId: accountId, apiClient: connection.apiClient) }
                #if DEBUG
                    AccountsDebugServices.shared.activeAccountDetailStore = store
                #endif
                await store?.load()
            }
    }

    @ViewBuilder
    private var content: some View {
        if let store {
            switch store.state {
            case .loading:
                ProgressView()
            case .failed(let message):
                ErrorStateView(message: message) { Task { await store.load() } }
            case .loaded:
                if let account = store.account {
                    Form {
                        StatusSection(store: store, account: account)
                        SyncToggleSection(store: store, environment: environment)
                        DetailsSection(account: account)
                        IconSection(store: store, environment: environment)

                        Section {
                            NavigationLink("Folder Order & Visibility", value: Route.folderOrder(accountId))
                            NavigationLink("Image Exceptions", value: Route.imageExceptions(accountId))
                            NavigationLink("Sending Identities", value: Route.identities(accountId))
                        }

                        Section {
                            Button("Sync Now") { Task { try? await store.triggerSync() } }
                            Button("Edit…") { showingEditSheet = true }
                            Button("Delete Account…", role: .destructive) { confirmDelete = true }
                        }
                    }
                }
            }
        }
    }

    private func delete() async {
        do {
            try await store?.delete()
            dismiss()
        } catch {
            let message = (error as? MVError)?.userMessage ?? "\(error)"
            environment.toasts.show(.init(variant: .error, message: "Could not delete the account: \(message)"))
        }
    }
}

private struct StatusSection: View {
    let store: MVAccountDetailStore
    let account: AccountResponse

    var body: some View {
        Section {
            if let stateError = account.stateError, !stateError.isEmpty {
                if store.connectionState == .retrying {
                    Text("Reconnecting after: \(stateError)").foregroundStyle(.secondary)
                } else {
                    Text(stateError).foregroundStyle(.red)
                }
            }
            if let syncStatus = store.syncStatus {
                LabeledContent("Sync tier", value: syncStatus.syncTier ?? "pending")
                if syncStatus.errorCount > 0 {
                    Text("\(syncStatus.errorCount) errors — \(syncStatus.lastError ?? "")").foregroundStyle(.red)
                }
            }
        } footer: {
            VStack(alignment: .leading, spacing: 2) {
                if let syncStatus = store.syncStatus {
                    Text(MVAccountDetailStore.syncTierDescription(syncStatus.syncTier))
                }
                Text("Real-time sync via IMAP IDLE · periodic fallback every 60 s")
            }
        }
    }
}

private struct SyncToggleSection: View {
    let store: MVAccountDetailStore
    let environment: AppEnvironment

    var body: some View {
        Section {
            Toggle(
                "Sync Enabled",
                isOn: Binding(
                    get: { store.account?.isActive ?? false },
                    set: { newValue in
                        Task {
                            do {
                                try await store.setActive(newValue)
                            } catch {
                                let message = (error as? MVError)?.userMessage ?? "\(error)"
                                environment.toasts.show(
                                    .init(variant: .error, message: "Could not change sync: \(message)"))
                            }
                        }
                    }
                ))
        }
    }
}

private struct DetailsSection: View {
    let account: AccountResponse

    var body: some View {
        Section("Details") {
            LabeledContent("User", value: account.imapUser)
            LabeledContent("Server", value: "\(account.imapHost):\(account.imapPort)")
            if let smtpHost = account.smtpHost {
                LabeledContent("SMTP user", value: account.smtpUser ?? account.imapUser)
                LabeledContent("SMTP server", value: "\(smtpHost):\(account.smtpPort ?? 0)")
            }
            LabeledContent("Spam detection", value: account.spamEnabled ? "Enabled" : "Disabled")
            LabeledContent(
                "Trash retention",
                value: account.trashRetentionDays.map { "\($0) days" } ?? "Off")
            LabeledContent(
                "Junk retention",
                value: account.junkRetentionDays.map { "\($0) days" } ?? "Off")
        }
    }
}

private struct IconSection: View {
    let store: MVAccountDetailStore
    let environment: AppEnvironment

    var body: some View {
        Section {
            HStack {
                Text("Icon")
                Spacer()
                EmojiPickerButton(currentEmoji: store.account?.emoji, accessibilityLabel: "Account icon") { emoji in
                    Task {
                        do {
                            try await store.setEmoji(emoji)
                        } catch {
                            let message = (error as? MVError)?.userMessage ?? "\(error)"
                            environment.toasts.show(
                                .init(variant: .error, message: "Could not set the icon: \(message)"))
                        }
                    }
                }
            }
        }
    }
}
