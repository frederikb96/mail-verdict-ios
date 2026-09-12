import MailVerdictKit
import SwiftUI

/// A calendar event, read-only — where the invitation card's "Event Details" links lead. Calendar
/// screens are out of this app's scope, so this sheet is the whole of it: no editing, nowhere to
/// navigate on to.
struct EventDetailsSheet: View {
    let objectId: UUID
    let calendars: [MVCalendar]
    let api: MVApiClient

    @State private var event: EventInstance?
    @State private var failure: String?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Group {
                if let event {
                    details(event)
                } else if let failure {
                    ErrorStateView(message: failure) { Task { await load() } }
                } else {
                    ProgressView()
                }
            }
            .navigationTitle("Event Details")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .task { await load() }
    }

    private func load() async {
        failure = nil
        do {
            event = try await api.getEvent(objectId: objectId)
        } catch {
            failure = error.mvUserMessage
        }
    }

    private func details(_ event: EventInstance) -> some View {
        let timeZone = event.tz.flatMap(TimeZone.init(identifier:)) ?? .current
        let calendar = calendars.first { $0.id == event.calendarId }
        return Form {
            Section {
                Text(event.summary.isEmpty ? "(no title)" : event.summary).font(.headline)
                LabeledContent(
                    "When",
                    value: InvitationCardBuilder.eventTimeText(
                        start: event.dtstart, end: event.dtend, allDay: event.allDay, timeZone: timeZone))
                if let tz = event.tz, !event.allDay {
                    LabeledContent("Time Zone", value: tz)
                }
                if let location = event.location, !location.isEmpty {
                    LabeledContent("Location", value: location)
                }
                if let organizer = event.organizer {
                    LabeledContent("Organizer", value: organizer.cn ?? organizer.email)
                }
                if event.rrule != nil {
                    Label("Repeats", systemImage: "repeat")
                }
            }
            if !event.attendees.isEmpty {
                Section("Attendees") {
                    ForEach(event.attendees, id: \.email) { attendee in
                        Label {
                            Text(attendee.cn ?? attendee.email)
                        } icon: {
                            Image(systemName: symbol(for: attendee.partstat)).foregroundStyle(
                                tint(for: attendee.partstat))
                        }
                    }
                }
            }
            if let calendar {
                Section("Calendar") {
                    Label {
                        Text(calendar.displayName)
                    } icon: {
                        Circle().fill(color(hex: CalendarColor.resolve(calendar))).frame(width: 12, height: 12)
                    }
                }
            }
            if let description = event.description, !description.isEmpty {
                Section("Notes") {
                    Text(description)
                }
            }
        }
    }

    private func symbol(for partstat: MVPartstat) -> String {
        switch partstat {
        case .accepted: return "checkmark.circle.fill"
        case .declined: return "xmark.circle.fill"
        case .tentative: return "questionmark.circle.fill"
        case .needsAction: return "circle"
        }
    }

    private func tint(for partstat: MVPartstat) -> Color {
        switch partstat {
        case .accepted: return .green
        case .declined: return .red
        case .tentative: return .orange
        case .needsAction: return .secondary
        }
    }

    /// `CalendarColor` resolves to a validated `#rrggbb`-style string for the page's markup; this
    /// turns it into a `Color` for the sheet.
    private func color(hex: String) -> Color {
        var value: UInt64 = 0
        Scanner(string: String(hex.dropFirst()).prefix(6).description).scanHexInt64(&value)
        return Color(
            red: Double((value >> 16) & 0xFF) / 255, green: Double((value >> 8) & 0xFF) / 255,
            blue: Double(value & 0xFF) / 255)
    }
}
