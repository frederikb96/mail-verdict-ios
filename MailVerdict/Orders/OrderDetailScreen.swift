import MailVerdictKit
import QuickLook
import SwiftUI

/// One order's detail -- summary, numbers, documents and its mails in time order, plus the three
/// corrections a person can make here: remove a mail, rewrite the summary, delete the order.
struct OrderDetailScreen: View {
    let orderId: UUID
    let environment: AppEnvironment
    let connection: AppEnvironment.Connection

    @State private var store: OrderDetailStore
    @State private var quickLookURL: URL?
    @State private var pendingRemove: OrderMailOut?
    @State private var confirmDelete = false
    @State private var didRequestDelete = false
    @Environment(\.dismiss) private var dismiss

    init(orderId: UUID, environment: AppEnvironment, connection: AppEnvironment.Connection) {
        self.orderId = orderId
        self.environment = environment
        self.connection = connection
        let freshStore = OrderDetailStore(orderId: orderId, apiClient: connection.apiClient)
        self._store = State(initialValue: freshStore)
        #if DEBUG
            OrdersFixtures.activeDetailStore = freshStore
        #endif
    }

    var body: some View {
        content
            .navigationTitle(store.order?.merchant ?? "Order")
            .navigationBarTitleDisplayMode(.inline)
            .accessibilityIdentifier("order-detail-screen")
            #if DEBUG
                // Ahead of the data-loading `.task` below, on purpose: a fixture-mode sweep's own
                // screenshot-readiness task registers this screen's routes, and it has to win the
                // race against this screen's own load -- an unregistered route falls back to a
                // 404, which this store reads as "the order is gone" and dismisses the screen
                // before it or its own readiness task ever settles.
                .screenshotReady(route: .order(orderId), environment: environment, connection: connection)
            #endif
            .toolbar { toolbarContent }
            .quickLookPreview($quickLookURL)
            .removeMailDialog(pendingRemove: $pendingRemove) { mail in Task { await remove(mail) } }
            .deleteOrderAlert(isPresented: $confirmDelete) { Task { await delete() } }
            .task {
                ReaderSourceRegistry.shared.register(store, for: .order(orderId))
                store.subscribeToLive(connection.liveEventHub)
                await store.load()
            }
            .onDisappear { store.unsubscribeFromLive(connection.liveEventHub) }
            .onChange(of: store.wasDeleted) { _, deleted in
                guard deleted else { return }
                if !didRequestDelete {
                    environment.toasts.show(.init(variant: .info, message: "This order no longer exists."))
                }
                dismiss()
            }
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            Menu {
                Button("Rewrite Summary") { Task { try? await store.rewrite() } }
                Button("Delete Order…", role: .destructive) { confirmDelete = true }
            } label: {
                Image(systemName: MVSymbols.options)
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        if let errorMessage = store.errorMessage {
            ErrorStateView(message: errorMessage) { Task { await store.load() } }
        } else if let order = store.order {
            List {
                OrderHeaderSection(order: order)
                OrderSummarySection(order: order)
                if !order.identifiers.isEmpty {
                    OrderNumbersSection(identifiers: order.identifiers, environment: environment)
                }
                if !order.documents.isEmpty {
                    OrderDocumentsSection(documents: order.documents, onOpen: openDocument)
                }
                OrderMailsSection(
                    mails: order.mails, orderId: orderId, environment: environment, pendingRemove: $pendingRemove)
            }
            .listStyle(.insetGrouped)
        } else {
            // Covers both the genuine loading state and the brief instant before `.task` has
            // run at all -- `store.isLoading` starts `false`, so without this fallback the very
            // first render (no error, no order, not yet loading) would draw nothing.
            ProgressView()
        }
    }

    private func remove(_ mail: OrderMailOut) async {
        do {
            try await store.detachMail(mail)
        } catch {
            environment.toasts.show(.init(variant: .error, message: "Could not remove: \(error.mvUserMessage)"))
        }
    }

    private func delete() async {
        didRequestDelete = true
        do {
            try await store.delete()
            dismiss()
        } catch {
            didRequestDelete = false
            environment.toasts.show(.init(variant: .error, message: "Could not delete: \(error.mvUserMessage)"))
        }
    }

    private func openDocument(_ document: OrderDocumentOut) {
        Task {
            do {
                let result = try await connection.apiClient.getAttachment(
                    messageId: document.messageId, attachmentId: document.attachmentId)
                quickLookURL = try Self.writeTemp(result.data, filename: document.filename)
            } catch {
                environment.toasts.show(.init(variant: .error, message: "Could not download: \(error.mvUserMessage)"))
            }
        }
    }

    private static func writeTemp(_ data: Data, filename: String) throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "order-documents", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent(filename.isEmpty ? "document" : filename)
        try data.write(to: url, options: .atomic)
        return url
    }
}

extension View {
    fileprivate func removeMailDialog(
        pendingRemove: Binding<OrderMailOut?>, onConfirm: @escaping (OrderMailOut) -> Void
    ) -> some View {
        confirmationDialog(
            "Remove this mail from the order?",
            isPresented: Binding(
                get: { pendingRemove.wrappedValue != nil }, set: { if !$0 { pendingRemove.wrappedValue = nil } }),
            presenting: pendingRemove.wrappedValue
        ) { mail in
            Button("Remove", role: .destructive) { onConfirm(mail) }
        } message: { _ in
            Text("It is never bundled into this order again.")
        }
    }

    fileprivate func deleteOrderAlert(isPresented: Binding<Bool>, onConfirm: @escaping () -> Void) -> some View {
        alert("Delete this order?", isPresented: isPresented) {
            Button("Delete", role: .destructive, action: onConfirm)
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Its mails stay where they are.")
        }
    }
}

private struct OrderHeaderSection: View {
    let order: OrderDetail

    var body: some View {
        Section {
            HStack(alignment: .top, spacing: 12) {
                RoundedRectangle(cornerRadius: 12)
                    .fill(MVPalette.orderTint(order.icon).opacity(0.15))
                    .frame(width: 48, height: 48)
                    .overlay {
                        Image(systemName: MVSymbols.orderIcon(order.icon))
                            .font(.title3.weight(.semibold))
                            .foregroundStyle(MVPalette.orderTint(order.icon))
                    }
                VStack(alignment: .leading, spacing: 6) {
                    Text(order.merchant.uppercased())
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Text(order.subject)
                        .font(.title3.weight(.semibold))
                        .lineLimit(3)
                    HStack(spacing: 6) {
                        if !order.status.isEmpty {
                            Chip(text: order.status.capitalized, tint: order.isOpen ? .blue : .secondary)
                        }
                        Text(
                            "\(order.mailCount) mail\(order.mailCount == 1 ? "" : "s") · \(MVDateFormat.dateRange(order.firstMailAt, order.lastMailAt))"
                        )
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                }
            }
            .listRowInsets(EdgeInsets())
            .padding(.vertical, 8)
        }
        .listRowBackground(Color.clear)
    }
}

private struct OrderSummarySection: View {
    let order: OrderDetail

    var body: some View {
        Section("Summary") {
            ForEach(Array(OrderSummaryDocument.parse(order.summary).enumerated()), id: \.offset) { _, block in
                switch block {
                case .paragraph(let inlines):
                    inlineText(inlines).font(.subheadline)
                case .bullets(let items):
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(Array(items.enumerated()), id: \.offset) { _, inlines in
                            HStack(alignment: .firstTextBaseline, spacing: 8) {
                                Text("•")
                                inlineText(inlines)
                            }
                        }
                    }
                    .font(.subheadline)
                }
            }
            if order.textStale {
                Text("Updating the summary…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func inlineText(_ inlines: [OrderSummaryInline]) -> Text {
        inlines.reduce(Text("")) { partial, inline in
            partial + (inline.bold ? Text(inline.text).fontWeight(.semibold) : Text(inline.text))
        }
    }
}

private struct OrderNumbersSection: View {
    let identifiers: [OrderIdentifierOut]
    let environment: AppEnvironment

    var body: some View {
        Section("Numbers") {
            ForEach(Array(identifiers.enumerated()), id: \.offset) { _, identifier in
                Button {
                    UIPasteboard.general.string = identifier.value
                    environment.toasts.show(.init(variant: .info, message: "Copied", duration: 2))
                } label: {
                    LabeledContent(Self.label(for: identifier.kind)) {
                        Text(identifier.value).monospaced().foregroundStyle(.primary)
                    }
                }
                .accessibilityLabel("Copy \(Self.label(for: identifier.kind)) number \(identifier.value)")
            }
        }
    }

    private static func label(for kind: String) -> String {
        switch kind {
        case "order_number": return "Order"
        case "booking_code": return "Booking"
        case "tracking_number": return "Tracking"
        case "invoice_number": return "Invoice"
        case "ticket_number": return "Ticket"
        default: return kind.capitalized
        }
    }
}

private struct OrderDocumentsSection: View {
    let documents: [OrderDocumentOut]
    let onOpen: (OrderDocumentOut) -> Void

    var body: some View {
        Section("Documents") {
            ForEach(documents) { document in
                Button {
                    onOpen(document)
                } label: {
                    HStack {
                        Label(document.filename, systemImage: Self.icon(for: document.contentType))
                            .lineLimit(1)
                        Spacer()
                        Text(formatSize(document.sizeBytes)).font(.caption).foregroundStyle(.secondary)
                    }
                }
                .foregroundStyle(.primary)
            }
        }
    }

    private static func icon(for contentType: String) -> String {
        switch contentType {
        case "application/pdf": return "doc.text"
        case "application/vnd.apple.pkpass": return "wallet.pass"
        case "text/calendar", "application/ics": return "calendar"
        default: return "doc"
        }
    }
}

private struct OrderMailsSection: View {
    let mails: [OrderMailOut]
    let orderId: UUID
    let environment: AppEnvironment
    @Binding var pendingRemove: OrderMailOut?

    var body: some View {
        Section("Mails") {
            ForEach(mails) { mail in
                row(for: mail)
                    .swipeActions(edge: .trailing) {
                        Button("Remove", role: .destructive) { pendingRemove = mail }
                    }
            }
        }
    }

    @ViewBuilder
    private func row(for mail: OrderMailOut) -> some View {
        if let messageId = mail.messageId, !mail.isGone {
            NavigationLink(value: Route.reader(ReaderContext(source: .order(orderId), messageId: messageId))) {
                OrderMailRow(mail: mail)
            }
        } else {
            OrderMailRow(mail: mail)
                .opacity(0.5)
        }
    }
}

private struct OrderMailRow: View {
    let mail: OrderMailOut

    var body: some View {
        HStack(spacing: 10) {
            Circle()
                .strokeBorder(Color.secondary.opacity(mail.isSeen == false ? 0 : 0.4), lineWidth: 1)
                .background(Circle().fill(mail.isSeen == false ? MVPalette.unreadDot : Color.clear))
                .frame(width: 8, height: 8)
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text(extractSenderName(mail.fromAddr)).font(.subheadline.weight(.semibold)).lineLimit(1)
                    Spacer()
                    Text(MVDateFormat.relativeDate(mail.receivedAt)).font(.caption).foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                Text(mail.subject).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
            }
        }
    }
}
