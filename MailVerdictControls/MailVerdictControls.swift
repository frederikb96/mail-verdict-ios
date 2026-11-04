import AppIntents
import SwiftUI
import WidgetKit

/// The controls Control Center, the Lock Screen and the Action button offer. Each one runs the
/// shortcut intent of the same name, so a control lands exactly where its shortcut does.
@main
struct MailVerdictControls: WidgetBundle {
    var body: some Widget {
        NewMessageControl()
        OpenTicketsControl()
    }
}

struct NewMessageControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: "com.frederikberg.mailverdict.controls.new-message") {
            ControlWidgetButton(action: NewMessageIntent()) {
                Label("New Message", systemImage: "square.and.pencil")
            }
        }
        .displayName("New Message")
        .description("Start a new message in MailVerdict.")
    }
}

struct OpenTicketsControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: "com.frederikberg.mailverdict.controls.open-tickets") {
            ControlWidgetButton(action: OpenOpenTicketsIntent()) {
                Label("Open Tickets", systemImage: "ticket")
            }
        }
        .displayName("Open Tickets")
        .description("Show the tickets still open, on the timeline at today.")
    }
}
