/// Every event name `GET /api/events` can carry — mirrors the vendored
/// `Tests/MailVerdictKitTests/Fixtures/api-contract/sse-events.json` snapshot. `ContractTests`
/// asserts this enum's raw values equal that file exactly, both directions, so a name this client
/// ignores is a decision (a case with a no-op handler in `LiveEventHub`) rather than an accident.
public enum SSEEventName: String, Sendable, Equatable, CaseIterable, Codable {
    case connected
    case resync
    case mailNew = "mail.new"
    case mailUpdated = "mail.updated"
    case mailDeleted = "mail.deleted"
    case verdictIssued = "verdict.issued"
    case alertNew = "alert.new"
    case alertDismissed = "alert.dismissed"
    case notificationNew = "notification.new"
    case accountChanged = "account.changed"
    case folderSynced = "folder.synced"
    case folderChanged = "folder.changed"
    case outboxUpdated = "outbox.updated"
    case settingsChanged = "settings.changed"
    case identityChanged = "identity.changed"
    case calendarAccount = "calendar.account"
    case calendarCollection = "calendar.collection"
    case calendarLinksChanged = "calendar.links_changed"
    case calendarObject = "calendar.object"
    case contactCollection = "contact.collection"
    case contactObject = "contact.object"
    case pipelineDocumentChanged = "pipeline.document_changed"
    case pipelineNotify = "pipeline.notify"
    case pipelineRunFinished = "pipeline.run_finished"
}
