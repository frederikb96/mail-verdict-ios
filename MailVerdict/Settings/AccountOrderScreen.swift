import MailVerdictKit
import SwiftUI

/// Account display order — `.onMove` reorders and sends the new order after each move. There is
/// no separate Save step.
struct AccountOrderScreen: View {
    let environment: AppEnvironment
    let connection: AppEnvironment.Connection

    @State private var store: MVAccountOrderStore

    init(environment: AppEnvironment, connection: AppEnvironment.Connection) {
        self.environment = environment
        self.connection = connection
        _store = State(initialValue: MVAccountOrderStore(apiClient: connection.apiClient))
    }

    var body: some View {
        // `content` is never empty — `store` exists from the first render, so there is no nil
        // phase for a lifecycle modifier attached here to silently attach to nothing.
        content
            .navigationTitle("Account Order")
            .accessibilityIdentifier("accountorder-screen")
            #if DEBUG
                .screenshotReady(route: .accountOrder, environment: environment, connection: connection)
            #endif
            .task { await store.load() }
    }

    @ViewBuilder
    private var content: some View {
        switch store.state {
        case .loading:
            ProgressView()
        case .failed(let error):
            ErrorStateView(error: error) { Task { await store.load() } }
        case .loaded:
            List {
                ForEach(store.accounts) { account in
                    AccountOrderRow(account: account)
                }
                .onMove { offsets, destination in
                    Task {
                        do {
                            try await store.move(fromOffsets: offsets, toOffset: destination)
                        } catch {
                            environment.toasts.show(
                                .init(
                                    variant: .error,
                                    message: "Could not save the order: \(error.mvUserMessage)"))
                        }
                    }
                }
            }
            .environment(\.editMode, .constant(.active))
        }
    }
}

private struct AccountOrderRow: View {
    let account: AccountResponse

    var body: some View {
        HStack(spacing: 12) {
            Text(account.emoji ?? "📧")
            VStack(alignment: .leading) {
                Text(account.name).font(.body)
                Text(account.imapUser).font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}
