import MailVerdictKit
import SwiftUI

/// Account display order — `.onMove` reorders and sends the new order after each move, per the
/// UX design's "changes apply immediately".
struct AccountOrderScreen: View {
    let environment: AppEnvironment
    let connection: AppEnvironment.Connection

    @State private var store: MVAccountOrderStore?

    var body: some View {
        content
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
            case .failed(let message):
                ErrorStateView(message: message) { Task { await store.load() } }
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
                                let message = (error as? MVError)?.userMessage ?? "\(error)"
                                environment.toasts.show(
                                    .init(variant: .error, message: "Could not save the order: \(message)"))
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
