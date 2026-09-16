import MailVerdictKit
import QuickLook
import SwiftUI

/// The reader: the list's conversations one page each, paged sideways like Photos, zoomed like
/// Photos, with exactly three items in the bottom bar — Archive, Delete, Options.
struct ReaderScreen: View {
    let context: ReaderContext
    let environment: AppEnvironment
    let connection: AppEnvironment.Connection

    @State private var model: ReaderScreenModel?
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        Group {
            if let model {
                ReaderContent(model: model, api: connection.apiClient)
            } else {
                Color(uiColor: .systemBackground)
            }
        }
        .onAppear {
            guard model == nil else { return }
            #if DEBUG
                if MVFixtureLaunch.isEnabled() { ReaderFixtures.install() }
            #endif
            let dismiss = dismiss
            model = ReaderScreenModel(
                context: context, environment: environment, connection: connection, theme: canvas(colorScheme),
                close: { dismiss() })
        }
        .onChange(of: colorScheme) { _, scheme in
            model?.session.setTheme(canvas(scheme))
        }
        .onDisappear {
            model?.didDisappear()
        }
        #if DEBUG
            .screenshotReady(route: .reader(context), environment: environment, connection: connection)
        #endif
    }

    private func canvas(_ scheme: ColorScheme) -> MVCanvas {
        scheme == .dark ? .dark : .light
    }
}

private struct ReaderContent: View {
    @Bindable var model: ReaderScreenModel
    let api: MVApiClient

    var body: some View {
        ReaderPager(model: model)
            .ignoresSafeArea()
            .navigationTitle(model.session.title ?? "")
            .navigationSubtitle(model.session.currentActionStatusText ?? "")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { toolbar }
            .toolbar(.visible, for: .bottomBar)
            .confirmationDialog(
                model.addressChoice?.address ?? "", isPresented: isPresented($model.addressChoice),
                titleVisibility: .visible, presenting: model.addressChoice
            ) { choice in
                Button("Copy Address") { model.copy(choice.address) }
                Button("New Message to \(choice.address)") { model.compose(to: choice.address) }
                if choice.field != .from, choice.line.count > 1 {
                    Button(choice.field == .cc ? "Copy All Cc" : "Copy All To") {
                        model.copy(choice.line.joined(separator: ", "))
                    }
                }
            }
            .confirmationDialog(
                "Add to Calendar", isPresented: isPresented($model.calendarChoice), titleVisibility: .visible,
                presenting: model.calendarChoice
            ) { choice in
                ForEach(choice.calendars) { calendar in
                    Button(calendar.displayName) { model.addInvitation(choice, to: calendar.id) }
                }
            }
            .alert("Delete this message forever?", isPresented: $model.confirmingDeleteForever) {
                Button("Delete Forever", role: .destructive) { model.deleteForever() }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("This removes it from the mail server. It cannot be undone.")
            }
            .alert(
                model.phoneHandoffIsMessage ? "Send a Message?" : "Make a Call?",
                isPresented: isPresented($model.confirmingPhoneHandoff)
            ) {
                Button(model.phoneHandoffIsMessage ? "Send Message" : "Call") { model.confirmPhoneHandoff() }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text(model.confirmingPhoneHandoff?.absoluteString.split(separator: ":").last.map(String.init) ?? "")
            }
            .alert("Note to the Organizer", isPresented: isPresented($model.noteMessageId)) {
                TextField("Note", text: $model.noteText, axis: .vertical)
                Button("Save") { model.saveNote() }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Sent with your next reply.")
            }
            .sheet(item: $model.moveRequest) { request in
                MovePickerSheet(
                    source: .folders(accountId: request.accountId, excludingFolderId: request.currentFolderId),
                    backend: api
                ) { target in
                    model.move(to: target, accountId: request.accountId)
                }
            }
            .sheet(item: $model.eventDetails) { request in
                EventDetailsSheet(objectId: request.id, calendars: request.calendars, api: api)
            }
            .sheet(isPresented: $model.optionsPreview) {
                NavigationStack {
                    List { ReaderOptionsMenuContent(model: model) }
                        .navigationTitle("Options")
                        .navigationBarTitleDisplayMode(.inline)
                }
            }
            .quickLookPreview($model.quickLookURL)
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .topBarTrailing) {
            Button {
                model.page(.newer)
            } label: {
                Label("Previous Message", systemImage: MVSymbols.previousMessage)
            }
            .disabled(model.session.paging.newerId == nil)
            Button {
                model.page(.older)
            } label: {
                Label("Next Message", systemImage: MVSymbols.nextMessage)
            }
            .disabled(model.session.paging.olderId == nil)
        }
        ToolbarItem(placement: .bottomBar) {
            Button {
                model.archive()
            } label: {
                Label("Archive", systemImage: MVSymbols.archive)
            }
            .disabled(model.primary == nil || model.session.isCurrentInArchive)
            .accessibilityIdentifier("reader-archive")
        }
        ToolbarItem(placement: .bottomBar) {
            Group {
                if model.session.isCurrentInTrash {
                    Button(role: .destructive) {
                        model.confirmingDeleteForever = true
                    } label: {
                        Label("Delete Forever", systemImage: MVSymbols.deleteForever)
                    }
                } else {
                    Button {
                        model.delete()
                    } label: {
                        Label("Delete", systemImage: MVSymbols.delete)
                    }
                }
            }
            .disabled(model.primary == nil)
            .accessibilityIdentifier("reader-delete")
        }
        ToolbarSpacer(.flexible, placement: .bottomBar)
        ToolbarItem(placement: .bottomBar) {
            Menu {
                ReaderOptionsMenuContent(model: model)
            } label: {
                Label("Options", systemImage: MVSymbols.options)
            }
            .disabled(model.primary == nil)
            .accessibilityIdentifier("reader-options")
        }
    }

    private func isPresented<T>(_ binding: Binding<T?>) -> Binding<Bool> {
        Binding(get: { binding.wrappedValue != nil }, set: { if !$0 { binding.wrappedValue = nil } })
    }
}

/// The Options menu: `MessageActionSet`'s groups for the current message, in its order.
struct ReaderOptionsMenuContent: View {
    let model: ReaderScreenModel

    var body: some View {
        if let context = model.session.optionsContext() {
            let groups = MessageActionSet.actions(for: context)
            ForEach(groups.indices, id: \.self) { index in
                group(groups[index], context: context)
            }
        }
    }

    @ViewBuilder
    private func group(_ group: MVMessageActionGroup, context: MVMessageContext) -> some View {
        switch group.kind {
        case .respond:
            ControlGroup { buttons(group.actions) }
        case .verdict:
            if let verdict = context.verdict {
                Section(MVMessageUIAction.verdictGroupTitle(verdict)) {
                    ControlGroup { buttons(group.actions) }
                }
            }
        case .tools:
            Section {
                let shown = tools(group.actions)
                ForEach(shown.indices, id: \.self) { index in
                    let action = shown[index]
                    if action == .loadImagesOnce {
                        Menu {
                            buttons(group.actions.filter(\.isRemoteImagesChoice))
                        } label: {
                            Label("Remote Images", systemImage: MVSymbols.remoteImages)
                        }
                    } else {
                        button(action)
                    }
                }
            }
        case .state, .destructive:
            Section { buttons(group.actions) }
        }
    }

    /// The remote-images choices collapse into one submenu, and the canvas toggle only applies to
    /// an HTML body.
    private func tools(_ actions: [MVMessageUIAction]) -> [MVMessageUIAction] {
        actions.filter { action in
            if action == .alwaysLoadFromSender || action == .alwaysLoadFromDomain { return false }
            if action == .darkBackground || action == .lightBackground { return model.session.currentHasHTMLBody }
            return true
        }
    }

    /// Identified by position: the actions are unique within a group, and the enum is only
    /// `Equatable`.
    private func buttons(_ actions: [MVMessageUIAction]) -> some View {
        ForEach(actions.indices, id: \.self) { index in
            button(actions[index])
        }
    }

    private func button(_ action: MVMessageUIAction) -> some View {
        Button(role: action.isDestructive ? .destructive : nil) {
            model.perform(action)
        } label: {
            Label(
                action.readerTitle(senderEmail: model.senderEmail, senderDomain: model.senderDomain),
                systemImage: action.symbol)
        }
    }
}

private struct ReaderPager: UIViewControllerRepresentable {
    let model: ReaderScreenModel

    func makeUIViewController(context: Context) -> ReaderViewController {
        let controller = ReaderViewController(model: model)
        model.pager = controller
        return controller
    }

    func updateUIViewController(_ controller: ReaderViewController, context: Context) {}
}
