import Foundation

/// One complete `text/event-stream` record.
public struct MVSseRecord: Sendable, Equatable {
    /// The value a reconnect sends back as `Last-Event-ID`. The backend's event ring prefixes
    /// every id with its own epoch (`"<epoch>-<seq>"`) so a client reconnecting after a restart
    /// can tell "mine, replay from here" from "a previous process's id, resync instead" — this
    /// client carries that string opaquely rather than parsing it, since only the server needs
    /// to understand its own shape.
    public let id: String?
    public let name: String
    public let data: String
}

/// Accumulates `id:`/`event:`/`data:` lines into complete SSE records, framed by a blank line —
/// pulled out of the streaming client specifically so the framing rules can be exercised on the
/// free Linux runner. The client itself cannot build there (`URLSession` is Apple-only); this
/// type touches neither `URLSession` nor anything else platform-specific, so it stays on every
/// platform while the transport around it does not.
struct MVSseEventAccumulator: Sendable, Equatable {
    private var eventId: String?
    private var eventName: String?
    private var dataLines: [String] = []

    /// Feeds one line of a `text/event-stream` body. Returns the completed record the moment a
    /// blank line terminates it; returns `nil` while a record is still accumulating, including
    /// when the blank line arrives with no event name or no data lines — an incomplete record is
    /// discarded, not emitted.
    mutating func ingest(line: String) -> MVSseRecord? {
        if line.isEmpty {
            defer {
                eventId = nil
                eventName = nil
                dataLines = []
            }
            guard let name = eventName, !dataLines.isEmpty else { return nil }
            return MVSseRecord(id: eventId, name: name, data: dataLines.joined(separator: "\n"))
        }
        // A line starting with `:` is an SSE comment — this backend sends `: keepalive` on an
        // idle connection specifically so an intermediary does not time the connection out, and
        // it carries no event data at all. Treating it as an unrecognised field would be
        // harmless (the `else` branch below already ignores unknown fields), but reads correctly
        // as "ignored on purpose" rather than "a field this client doesn't know about yet".
        if line.hasPrefix(":") { return nil }
        if line.hasPrefix("id:") {
            eventId = String(line.dropFirst("id:".count)).trimmingCharacters(in: .whitespaces)
        } else if line.hasPrefix("event:") {
            eventName = String(line.dropFirst("event:".count)).trimmingCharacters(in: .whitespaces)
        } else if line.hasPrefix("data:") {
            dataLines.append(Self.sseDataValue(from: line.dropFirst("data:".count)))
        }
        // Any other field (retry:, etc.) goes unused by this client.
        return nil
    }

    /// Per the SSE spec, at most one leading space after `data:` is stripped — the rest of the
    /// line, including any other leading or trailing whitespace, is data. `.trimmingCharacters`
    /// over-strips; JSON payloads survive that by luck (whitespace outside string literals is
    /// insignificant), but it is wrong on principle for a framing rule that events beyond JSON
    /// can carry through this same parser.
    static func sseDataValue(from line: Substring) -> String {
        line.first == " " ? String(line.dropFirst()) : String(line)
    }
}
