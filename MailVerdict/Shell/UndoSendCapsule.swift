import MailVerdictKit
import SwiftUI

/// The root undo-send host: one glass capsule per send still inside the server's undo window,
/// counting down, with Undo. It sits above the toast overlay. It is also where the composer's
/// launch-time checks live, since it is the one piece of the composer mounted for as long as the
/// app is connected: pending sends are fetched on appearance and on every return to the
/// foreground, and an unsent fresh message left by a crash is offered back.
struct UndoSendCapsule: View {
    let environment: AppEnvironment
    let connection: AppEnvironment.Connection

    @State private var store: UndoSendStore
    @State private var accountNames: [UUID: String] = [:]
    @Environment(\.scenePhase) private var scenePhase

    init(environment: AppEnvironment, connection: AppEnvironment.Connection) {
        self.environment = environment
        self.connection = connection
        _store = State(initialValue: UndoSendStore(dependencies: .live(client: connection.apiClient)))
    }

    var body: some View {
        VStack(spacing: 8) {
            Spacer()
            if !store.pending.isEmpty {
                TimelineView(.periodic(from: .now, by: 0.25)) { context in
                    VStack(spacing: 8) {
                        ForEach(store.visibleRows(now: context.date)) { row in
                            capsule(for: row, now: context.date)
                        }
                    }
                }
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .padding(.bottom, 64)
        .animation(.default, value: store.pending.map(\.id))
        .allowsHitTesting(!store.pending.isEmpty)
        .task {
            ComposerServices.shared.undoSend = store
            offerRecoveredMessage()
            await store.refresh()
            let accounts = (try? await connection.apiClient.listAccounts()) ?? []
            accountNames = Dictionary(uniqueKeysWithValues: accounts.map { ($0.id, $0.name) })
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { Task { await store.refresh() } }
        }
    }

    private func capsule(for row: PendingSendResponse, now: Date) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "paperplane")
                .foregroundStyle(.secondary)
            Text("Sending in \(UndoSendStore.secondsRemaining(until: row.sendAfter, now: now))s…")
                .font(.subheadline)
                .monospacedDigit()
            if accountNames.count > 1, let name = accountNames[row.accountId] {
                Chip(text: name)
            }
            Button("Undo") { Task { await undo(row) } }
                .font(.subheadline.weight(.semibold))
                .disabled(store.cancelling.contains(row.id))
                .accessibilityIdentifier("undo-send")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.thinMaterial, in: Capsule())
        .shadow(radius: 8)
        .padding(.horizontal)
    }

    private func undo(_ row: PendingSendResponse) async {
        switch await store.undo(row.id) {
        case .restored(let intent):
            environment.toasts.show(MVToast(variant: .success, message: "Send cancelled"))
            environment.presentedCompose = intent
        case .tooLate:
            environment.toasts.show(MVToast(variant: .warning, message: "Too late — the message already sent"))
        case .ignored:
            break
        }
    }

    /// A fresh message's snapshot surviving to launch means the app ended while one was being
    /// written; opening a new composer offers it back through the composer's own Restore banner.
    private func offerRecoveredMessage() {
        let key = ComposeRecoveryStore.key(replacesMessageId: nil, inReplyTo: nil)
        guard ComposerServices.shared.recovery.hasSnapshot(key: key) else { return }
        let environment = environment
        environment.toasts.show(
            MVToast(
                variant: .info, message: "You have an unsent message", duration: 0, actionTitle: "Open",
                action: {
                    Task { @MainActor in environment.presentedCompose = ComposeIntent(kind: .new(accountId: nil)) }
                }))
    }
}
