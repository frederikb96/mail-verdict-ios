import MailVerdictKit
import SwiftUI

/// Account display order — `.onMove` reorders and sends the new order after each move. There is
/// no separate Save step.
struct AccountOrderScreen: View {
    let environment: AppEnvironment
    let connection: AppEnvironment.Connection

    @State private var store: MVAccountOrderStore?

    var body: some View {
        // `content` renders nothing at all before `store` exists — wrapped in `Group` so `.task`
        // below is attached to a container that is there from the very first render, never to a
        // view whose own presence depends on the state that same task is about to create.
        Group {
            content
        }
        .navigationTitle("Account Order")
        .accessibilityIdentifier("accountorder-screen")
        #if DEBUG
            .screenshotReady(route: .accountOrder, environment: environment, connection: connection)
        #endif
        .task {
            if store == nil { store = MVAccountOrderStore(apiClient: connection.apiClient) }
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
