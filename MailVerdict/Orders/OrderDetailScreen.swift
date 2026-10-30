import MailVerdictKit
import QuickLook
import SwiftUI

/// One order's detail -- summary, key facts with their codes, documents and its mails in time
/// order, plus the corrections a person can make here: remove a mail, rewrite the summary, delete
/// the order, add or delete a file, and the flags (favorite, closed, sealed) and the kind through
/// the Options menu.
struct OrderDetailScreen: View {
    let orderId: UUID
    let environment: AppEnvironment
    let connection: AppEnvironment.Connection

    @State private var store: OrderDetailStore
    @State private var quickLookURL: URL?
    @State private var pendingRemove: OrderMailOut?
    @State private var pendingDeleteFile: OrderDocumentOut?
    @State private var isImportingFile = false
    @State private var isPickingPhoto = false
    @State private var confirmDelete = false
    @State private var didRequestDelete = false
    @Environment(\.dismiss) private var dismiss

    init(orderId: UUID, environment: AppEnvironment, connection: AppEnvironment.Connection) {
        self.orderId = orderId
        self.environment = environment
        self.connection = connection
        let freshStore = OrderDetailStore(
            orderId: orderId, apiClient: connection.apiClient, offlineCache: connection.offlineCache)
        self._store = State(initialValue: freshStore)
        #if DEBUG
            OrdersFixtures.activeDetailStore = freshStore
        #endif
    }

    /// The presentation modifiers are split over three properties: a body chaining this many
    /// alerts, dialogs and covers is a type check the compiler gives up on.
    var body: some View {
        screen
            .quickLookPreview($quickLookURL)
            .removeMailDialog(pendingRemove: $pendingRemove) { mail in Task { await remove(mail) } }
            .deleteOrderAlert(isPresented: $confirmDelete) { Task { await delete() } }
            .deleteFileDialog(pending: $pendingDeleteFile) { document in Task { await deleteFile(document) } }
            .modifier(filePicking)
            .fullScreenCover(isPresented: codeIsPresented) { codeScreen }
    }

    private var filePicking: some ViewModifier {
        OrderFilePickingModifier(
            isImporting: $isImportingFile, isPickingPhoto: $isPickingPhoto,
            onPicked: { file in
                Task {
                    await store.addFile(data: file.data, filename: file.filename, contentType: file.contentType)
                }
            },
            onFailure: { error in
                environment.toasts.show(
                    .init(variant: .error, message: "Could not add the file: \(error.mvUserMessage)"))
            })
    }

    private var screen: some View {
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
            .safeAreaInset(edge: .top, spacing: 0) { offlineNotice }
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
                if let order = store.order {
                    OrderActionMenuItems(flags: order.flags) { action in run(action) }
                    Divider()
                    Menu {
                        ForEach(OrderKind.allCases, id: \.self) { kind in
                            Button {
                                setKind(kind)
                            } label: {
                                if order.kind == kind {
                                    Label(kind.label, systemImage: "checkmark")
                                } else {
                                    Text(kind.label)
                                }
                            }
                        }
                    } label: {
                        Label("Kind: \(order.kind.label)", systemImage: "tag")
                    }
                }
            } label: {
                Image(systemName: MVSymbols.options)
            }
            .disabled(store.order == nil)
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
                if !order.facts.isEmpty {
                    OrderFactsSection(store: store, order: order, environment: environment)
                }
                OrderDocumentsSection(
                    documents: order.documents, uploads: store.uploads, onOpen: openDocument,
                    onDelete: { pendingDeleteFile = $0 }, onDismissUpload: { store.dismissUpload($0) },
                    onAddFile: { isImportingFile = true }, onAddPhoto: { isPickingPhoto = true })
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

    private func run(_ action: OrderAction) {
        if action == .delete {
            confirmDelete = true
            return
        }
        Task {
            do {
                if let message = try await store.perform(action) {
                    environment.toasts.show(.init(variant: .info, message: message, duration: 2.5))
                }
            } catch {
                environment.toasts.show(.init(variant: .error, message: "Could not update: \(error.mvUserMessage)"))
            }
        }
    }

    private func setKind(_ kind: OrderKind) {
        Task {
            do {
                try await store.setKind(kind)
            } catch {
                environment.toasts.show(.init(variant: .error, message: "Could not update: \(error.mvUserMessage)"))
            }
        }
    }

    private func deleteFile(_ document: OrderDocumentOut) async {
        do {
            try await store.deleteFile(document)
        } catch {
            environment.toasts.show(.init(variant: .error, message: "Could not delete: \(error.mvUserMessage)"))
        }
    }

    private var codeIsPresented: Binding<Bool> {
        Binding(
            get: { store.presentedCodeFactId != nil },
            set: { if !$0 { store.presentedCodeFactId = nil } })
    }

    @ViewBuilder
    private var codeScreen: some View {
        if let id = store.presentedCodeFactId, let fact = store.order?.facts.first(where: { $0.id == id }) {
            OrderCodeScreen(store: store, fact: fact) { store.presentedCodeFactId = nil }
        }
    }

    @ViewBuilder
    private var offlineNotice: some View {
        if let notice = MVOfflineNotice.make(reachability: connection.reachability, savedAt: store.savedCopyAt) {
            OfflineCapsule(notice: notice)
                .accessibilityIdentifier("order-offline")
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
                let data = try await store.downloadDocument(document)
                quickLookURL = try Self.writeTemp(data, filename: document.filename)
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
}

extension View {
    fileprivate func deleteFileDialog(
        pending: Binding<OrderDocumentOut?>, onConfirm: @escaping (OrderDocumentOut) -> Void
    ) -> some View {
        confirmationDialog(
            "Delete this file?",
            isPresented: Binding(get: { pending.wrappedValue != nil }, set: { if !$0 { pending.wrappedValue = nil } }),
            presenting: pending.wrappedValue
        ) { document in
            Button("Delete", role: .destructive) { onConfirm(document) }
        } message: { document in
            Text("\(document.filename) is removed from this order. Mail attachments are never touched.")
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
                    if order.kind == .ticket,
                        let day = MVDateFormat.eventRange(start: order.eventStart, end: order.eventEnd)
                    {
                        Label(day, systemImage: "calendar")
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(.orange)
                    }
                    HStack(spacing: 6) {
                        if order.isFavorite {
                            Image(systemName: MVSymbols.starFilled).foregroundStyle(.yellow)
                                .accessibilityLabel("Favorite")
                        }
                        if order.isSealed {
                            Image(systemName: "lock.fill").foregroundStyle(.secondary)
                                .accessibilityLabel("Sealed, takes no more mail")
                        }
                        if !order.status.isEmpty {
                            Chip(text: order.status.capitalized, tint: order.isOpen ? .blue : .secondary)
                        }
                        Text(
                            "\(countText) · \(MVDateFormat.dateRange(order.firstMailAt, order.lastMailAt))"
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

extension OrderHeaderSection {
    fileprivate var countText: String {
        var parts = ["\(order.mailCount) mail\(order.mailCount == 1 ? "" : "s")"]
        if order.fileCount > 0 { parts.append("\(order.fileCount) file\(order.fileCount == 1 ? "" : "s")") }
        return parts.joined(separator: " · ")
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

private struct OrderDocumentsSection: View {
    let documents: [OrderDocumentOut]
    let uploads: [OrderUpload]
    let onOpen: (OrderDocumentOut) -> Void
    let onDelete: (OrderDocumentOut) -> Void
    let onDismissUpload: (UUID) -> Void
    let onAddFile: () -> Void
    let onAddPhoto: () -> Void

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
                        if document.barcodeCount > 0 {
                            Image(systemName: "qrcode").font(.caption).foregroundStyle(.secondary)
                                .accessibilityLabel("Contains a code")
                        }
                        Text(formatSize(document.sizeBytes)).font(.caption).foregroundStyle(.secondary)
                    }
                    .contentShape(Rectangle())
                }
                .foregroundStyle(.primary)
                .disabled(document.downloadUrl == nil)
                .swipeActions(edge: .trailing) {
                    if document.isFile {
                        Button("Delete", role: .destructive) { onDelete(document) }
                    }
                }
            }
            ForEach(uploads) { upload in
                HStack(spacing: 10) {
                    switch upload.state {
                    case .uploading, .analysing:
                        ProgressView()
                        VStack(alignment: .leading, spacing: 2) {
                            Text(upload.filename).lineLimit(1)
                            Text(upload.state == .uploading ? "Uploading…" : "Analysing…")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    case .failed(let message):
                        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(upload.filename).lineLimit(1)
                            Text(message).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Dismiss") { onDismissUpload(upload.id) }
                            .font(.caption)
                            .buttonStyle(.borderless)
                    }
                }
            }
            Button(action: onAddFile) {
                Label("Add File…", systemImage: "doc.badge.plus")
            }
            .accessibilityIdentifier("order-add-file")
            Button(action: onAddPhoto) {
                Label("Add Photo…", systemImage: "photo.badge.plus")
            }
            .accessibilityIdentifier("order-add-photo")
        }
    }

    private static func icon(for contentType: String) -> String {
        switch contentType {
        case "application/pdf": return "doc.text"
        case "application/vnd.apple.pkpass": return "wallet.pass"
        case "text/calendar", "application/ics": return "calendar"
        default:
            return contentType.hasPrefix("image/") ? "photo" : "doc"
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
