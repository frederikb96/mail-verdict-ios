import Foundation
import MailVerdictKit
import SwiftUI

/// Remote-image allowlist — view and delete only; an exception is added from the reader, never
/// here. A direct port of the web's `ImageExceptionsList`.
struct ImageExceptionsScreen: View {
    let accountId: UUID
    let environment: AppEnvironment
    let connection: AppEnvironment.Connection

    @State private var store: MVImageExceptionsStore?

    var body: some View {
        content
            .navigationTitle("Image Exceptions")
            .accessibilityIdentifier("imageexceptions-screen")
            #if DEBUG
                .screenshotReady(
                    route: .imageExceptions(accountId), environment: environment, connection: connection
                )
            #endif
            .task {
                if store == nil {
                    store = MVImageExceptionsStore(accountId: accountId, apiClient: connection.apiClient)
                }
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
                if store.exceptions.isEmpty {
                    EmptyStateView(systemImage: "photo", message: "No image exceptions configured")
                } else {
                    List {
                        Section {
                            ForEach(store.exceptions) { exception in
                                ImageExceptionRow(exception: exception)
                            }
                            .onDelete { offsets in
                                for index in offsets {
                                    let exception = store.exceptions[index]
                                    Task {
                                        try? await store.delete(id: exception.id)
                                    }
                                }
                            }
                        } footer: {
                            Text("Senders and domains allowed to load remote images. Add exceptions from the reader.")
                        }
                    }
                }
            }
        }
    }
}

private struct ImageExceptionRow: View {
    let exception: ImageExceptionResponse

    var body: some View {
        HStack {
            Image(
                systemName: exception.type == MVImageExceptionType.sender.rawValue
                    ? MVSymbols.senderException : MVSymbols.domainException
            )
            .foregroundStyle(.secondary)
            Text(exception.value)
            Text("(\(exception.type))").font(.caption).foregroundStyle(.secondary)
            Spacer()
            Text(MVDateFormat.relativeAgo(exception.createdAt)).font(.caption).foregroundStyle(.secondary)
        }
    }
}
