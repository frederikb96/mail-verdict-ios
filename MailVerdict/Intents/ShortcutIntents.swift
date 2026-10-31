import AppIntents
import Foundation
import MailVerdictKit

/// Every action here brings the app to the front and parks where it should land, so a shortcut built
/// from one is one tap to that screen.
@MainActor
private func land(on target: MVShortcutTarget) -> some IntentResult {
    ShortcutInbox.shared.pending = target
    return .result()
}

struct NewMessageIntent: AppIntent {
    static var title: LocalizedStringResource { "New Message" }
    static var description: IntentDescription { IntentDescription("Start a new message in MailVerdict.") }
    static var openAppWhenRun: Bool { true }

    @MainActor
    func perform() async throws -> some IntentResult {
        land(on: .newMessage)
    }
}

struct OpenSearchIntent: AppIntent {
    static var title: LocalizedStringResource { "Search Mail" }
    static var description: IntentDescription { IntentDescription("Open search in MailVerdict.") }
    static var openAppWhenRun: Bool { true }

    @MainActor
    func perform() async throws -> some IntentResult {
        land(on: .search)
    }
}

struct OpenOrdersAndTicketsIntent: AppIntent {
    static var title: LocalizedStringResource { "Orders & Tickets" }
    static var description: IntentDescription { IntentDescription("Show all orders and tickets.") }
    static var openAppWhenRun: Bool { true }

    @MainActor
    func perform() async throws -> some IntentResult {
        land(on: .orders(OrderViewState()))
    }
}

struct OpenTicketsIntent: AppIntent {
    static var title: LocalizedStringResource { "Tickets" }
    static var description: IntentDescription { IntentDescription("Show the ticket timeline at today.") }
    static var openAppWhenRun: Bool { true }

    @MainActor
    func perform() async throws -> some IntentResult {
        land(on: .orders(OrderViewState(kind: .tickets)))
    }
}

struct OpenOpenTicketsIntent: AppIntent {
    static var title: LocalizedStringResource { "Open Tickets" }
    static var description: IntentDescription {
        IntentDescription("Show only the tickets still open, on the timeline at today.")
    }
    static var openAppWhenRun: Bool { true }

    @MainActor
    func perform() async throws -> some IntentResult {
        land(on: .orders(OrderViewState(kind: .tickets, open: true)))
    }
}

struct OpenOpenOrdersIntent: AppIntent {
    static var title: LocalizedStringResource { "Open Orders" }
    static var description: IntentDescription { IntentDescription("Show only the orders still open.") }
    static var openAppWhenRun: Bool { true }

    @MainActor
    func perform() async throws -> some IntentResult {
        land(on: .orders(OrderViewState(kind: .orders, open: true)))
    }
}

/// One unified view, chosen when the shortcut is built.
struct OpenUnifiedViewIntent: AppIntent {
    static var title: LocalizedStringResource { "Open Unified View" }
    static var description: IntentDescription { IntentDescription("Open a unified mail view.") }

    @Parameter(title: "Unified View")
    var view: UnifiedViewEntity

    init() {}

    static var openAppWhenRun: Bool { true }

    @MainActor
    func perform() async throws -> some IntentResult {
        land(on: .list(.unified(viewId: view.id, name: view.name)))
    }
}

/// A unified view as the Shortcuts app sees it.
struct UnifiedViewEntity: AppEntity, Identifiable, Hashable {
    let id: UUID
    let name: String
    let emoji: String?

    static var typeDisplayRepresentation: TypeDisplayRepresentation { "Unified View" }
    static var defaultQuery: UnifiedViewEntityQuery { UnifiedViewEntityQuery() }

    var displayRepresentation: DisplayRepresentation {
        let label = [emoji, name].compactMap { $0 }.joined(separator: " ")
        return DisplayRepresentation(title: "\(label)")
    }
}

/// Reads through its own client: Shortcuts asks while the app's connection may not exist.
struct UnifiedViewEntityQuery: EntityQuery {
    func entities(for identifiers: [UUID]) async throws -> [UnifiedViewEntity] {
        let wanted = Set(identifiers)
        return await allViews().filter { wanted.contains($0.id) }
    }

    func suggestedEntities() async throws -> [UnifiedViewEntity] {
        await allViews()
    }

    private func allViews() async -> [UnifiedViewEntity] {
        guard let client = MVKeychainCredentialStore().signedInClient(),
            let views = try? await client.listUnifiedFolders()
        else { return [] }
        return views.map { UnifiedViewEntity(id: $0.id, name: $0.unifiedName, emoji: $0.emoji) }
    }
}

/// What Siri, Spotlight and the Shortcuts app offer without the user building anything first.
/// Every phrase has to contain `\(.applicationName)`; one without it is rejected at build time on
/// Apple hardware only.
struct MailVerdictShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: NewMessageIntent(),
            phrases: ["New message in \(.applicationName)", "New \(.applicationName) message"],
            shortTitle: "New Message", systemImageName: "square.and.pencil")
        AppShortcut(
            intent: OpenOpenTicketsIntent(),
            phrases: ["Open tickets in \(.applicationName)", "\(.applicationName) open tickets"],
            shortTitle: "Open Tickets", systemImageName: "ticket")
        AppShortcut(
            intent: OpenTicketsIntent(),
            phrases: ["Tickets in \(.applicationName)", "\(.applicationName) tickets"],
            shortTitle: "Tickets", systemImageName: "calendar")
        AppShortcut(
            intent: OpenOpenOrdersIntent(),
            phrases: ["Open orders in \(.applicationName)", "\(.applicationName) open orders"],
            shortTitle: "Open Orders", systemImageName: "shippingbox")
        AppShortcut(
            intent: OpenOrdersAndTicketsIntent(),
            phrases: ["Orders and tickets in \(.applicationName)", "\(.applicationName) orders and tickets"],
            shortTitle: "Orders & Tickets", systemImageName: "tray.full")
        AppShortcut(
            intent: OpenUnifiedViewIntent(),
            phrases: ["Open a unified view in \(.applicationName)", "\(.applicationName) unified view"],
            shortTitle: "Unified View", systemImageName: "tray.2")
        AppShortcut(
            intent: OpenSearchIntent(),
            phrases: ["Search \(.applicationName)", "\(.applicationName) search"],
            shortTitle: "Search Mail", systemImageName: "magnifyingglass")
    }
}
