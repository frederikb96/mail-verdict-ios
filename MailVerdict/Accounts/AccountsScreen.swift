import MailVerdictKit
import SwiftUI

/// Every mail account, its state chip and sync recency — a direct port of the web's accounts
/// list, minus the per-account sub-screens, which live behind Account Detail here.
struct AccountsScreen: View {
    let environment: AppEnvironment
    let connection: AppEnvironment.Connection

    @State private var store: MVAccountsListStore?
    @State private var showingAddSheet = false

    var body: some View {
        content
            .navigationTitle("Accounts")
            .accessibilityIdentifier("accounts-screen")
            #if DEBUG
                .screenshotReady(route: .accounts, environment: environment, connection: connection)
            #endif
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        showingAddSheet = true
                    } label: {
                        Label("Add Account", systemImage: "plus")
                    }
                }
            }
            .sheet(isPresented: $showingAddSheet) {
                AccountFormView(mode: .create) { input in
                    guard let store else { return }
                    try await store.createAccount(input)
                }
            }
            .task {
                if store == nil { store = MVAccountsListStore(apiClient: connection.apiClient) }
                await store?.load()
            }
    }

    @ViewBuilder
    private var content: some View {
        if let store {
            switch store.state {
            case .loading:
                ProgressView()
            case .failed(let error):
                ErrorStateView(error: error) { Task { await store.load() } }
            case .loaded:
                if store.accounts.isEmpty {
                    EmptyStateView(
                        systemImage: "server.rack",
                        message: "No accounts configured",
                        actionTitle: "Add an email account to get started"
                    ) { showingAddSheet = true }
                } else {
                    List {
                        ForEach(store.accounts) { account in
                            NavigationLink(value: Route.account(account.id)) {
                                AccountRow(account: account, connectionState: store.connectionState(for: account))
                            }
                        }
                    }
                }
            }
        }
    }
}

private struct AccountRow: View {
    let account: AccountResponse
    let connectionState: MVAccountConnectionState

    var body: some View {
        HStack(spacing: 12) {
            Text(account.emoji ?? "📧").font(.title3)
            VStack(alignment: .leading, spacing: 2) {
                Text(account.name).font(.body)
                Text(account.imapUser).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            StateChip(account: account, connectionState: connectionState)
        }
    }
}

private struct StateChip: View {
    let account: AccountResponse
    let connectionState: MVAccountConnectionState

    var body: some View {
        Chip(text: label, tint: tint)
    }

    private var label: String {
        if connectionState == .retrying { return "Retrying" }
        switch account.state {
        case "created": return "Created"
        case "syncing": return "Syncing"
        case "disabled": return "Disabled"
        case "active": return "Active"
        case "error": return "Error"
        default: return account.state.capitalized
        }
    }

    private var tint: Color {
        if connectionState == .retrying { return .secondary }
        switch account.state {
        case "error": return .red
        case "active": return .blue
        default: return .secondary
        }
    }
}
