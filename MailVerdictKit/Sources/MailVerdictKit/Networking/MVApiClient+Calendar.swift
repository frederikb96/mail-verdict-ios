import Foundation

extension MVApiClient {

    public func getInvitation(messageId: UUID) async throws -> Invitation {
        try await send(path: "/api/calendar/invitations/\(messageId)")
    }

    public func importInvitation(
        messageId: UUID, _ request: ImportInvitationRequest
    ) async throws -> Invitation {
        try await send(
            path: "/api/calendar/invitations/\(messageId)/import", method: "POST",
            body: try Self.encodeBody(request)
        )
    }

    public func listCalendars() async throws -> [MVCalendar] {
        try await send(path: "/api/calendars")
    }

    public func getEvent(objectId: UUID, recurrenceId: String? = nil) async throws -> EventInstance {
        var query: [URLQueryItem] = []
        if let recurrenceId { query.append(URLQueryItem(name: "recurrence_id", value: recurrenceId)) }
        return try await send(path: "/api/calendar/events/\(objectId)", query: query)
    }

    public func respondToEvent(objectId: UUID, _ request: RespondRequest) async throws -> EventInstance {
        try await send(
            path: "/api/calendar/events/\(objectId)/respond", method: "POST",
            body: try Self.encodeBody(request)
        )
    }
}
