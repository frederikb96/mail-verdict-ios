import Foundation
import MailVerdictKit
import SwiftUI

/// Sending identities — list, set default, add, delete. A direct port of the web's
/// `IdentitiesSection`.
struct IdentitiesScreen: View {
    let accountId: UUID
    let environment: AppEnvironment
    let connection: AppEnvironment.Connection

    @State private var store: MVIdentitiesStore?
    @State private var newAddress = ""
    @State private var newDisplayName = ""

    var body: some View {
        content
            .navigationTitle("Identities")
            .accessibilityIdentifier("identities-screen")
            #if DEBUG
                .screenshotReady(route: .identities(accountId), environment: environment, connection: connection)
            #endif
            .task {
                if store == nil { store = MVIdentitiesStore(accountId: accountId, apiClient: connection.apiClient) }
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
                    Section {
                        if store.identities.isEmpty {
                            Text("No additional identities").foregroundStyle(.secondary)
                        } else {
                            ForEach(store.identities) { identity in
                                IdentityRow(store: store, identity: identity)
                            }
                            .onDelete { offsets in
                                for index in offsets {
                                    let identity = store.identities[index]
                                    Task { try? await store.delete(id: identity.id) }
                                }
                            }
                        }
                    }

                    Section {
                        TextField("Name", text: $newDisplayName)
                        HStack {
                            TextField("address@example.com", text: $newAddress)
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                                .keyboardType(.emailAddress)
                            Button {
                                Task { await addIdentity(store) }
                            } label: {
                                Image(systemName: "plus.circle.fill")
                            }
                            .disabled(newAddress.trimmingCharacters(in: .whitespaces).isEmpty)
                        }
                    }
                }
            }
        }
    }

    private func addIdentity(_ store: MVIdentitiesStore) async {
        let address = newAddress.trimmingCharacters(in: .whitespaces)
        guard !address.isEmpty else { return }
        let displayName = newDisplayName.trimmingCharacters(in: .whitespaces)
        do {
            try await store.createIdentity(address: address, displayName: displayName.isEmpty ? nil : displayName)
            newAddress = ""
            newDisplayName = ""
        } catch {
            environment.toasts.show(
                .init(variant: .error, message: "Could not add the identity: \(error.mvUserMessage)"))
        }
    }
}

private struct IdentityRow: View {
    let store: MVIdentitiesStore
    let identity: IdentityResponse

    var body: some View {
        HStack {
            Button {
                Task { try? await store.setDefault(id: identity.id) }
            } label: {
                Image(systemName: identity.isDefault ? MVSymbols.starFilled : MVSymbols.star)
                    .foregroundStyle(identity.isDefault ? MVPalette.star : .secondary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text(identity.isDefault ? "Default identity" : "Set as default"))

            VStack(alignment: .leading) {
                Text(identity.displayName ?? identity.address)
                if identity.displayName != nil {
                    Text(identity.address).font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }
}
