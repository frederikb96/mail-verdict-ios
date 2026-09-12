import Foundation

public enum ComposeRecipientField: String, CaseIterable, Sendable, Codable {
    case to, cc, bcc

    public var label: String {
        switch self {
        case .to: return "To"
        case .cc: return "Cc"
        case .bcc: return "Bcc"
        }
    }
}

public enum ComposeRecipients {

    /// Turns typed or pasted text into recipients. Each comma- or semicolon-separated entry is
    /// taken as a bare address or a `Name <address>` form; valid ones join `existing` (skipping any
    /// already there, case-insensitively) and invalid ones come back so the field can keep them in
    /// view — never silently accepted, never silently dropped.
    public static func commit(_ raw: String, into existing: [String]) -> (recipients: [String], invalid: [String]) {
        var recipients = existing
        var present = Set(existing.map { $0.lowercased() })
        var invalid: [String] = []
        for entry in parseAddressList(raw) {
            let candidate = normalize(entry)
            guard isValidEmail(candidate) else {
                invalid.append(entry)
                continue
            }
            if present.insert(candidate.lowercased()).inserted { recipients.append(candidate) }
        }
        return (recipients, invalid)
    }

    /// `Name <address>` becomes the address; anything else is only trimmed.
    public static func normalize(_ entry: String) -> String {
        let trimmed = entry.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.contains("<"), trimmed.contains(">") else { return trimmed }
        return extractEmail(trimmed).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public static func invalidNote(_ invalid: [String]) -> String? {
        invalid.isEmpty ? nil : "Not a valid email address: \(invalid.joined(separator: ", "))"
    }
}
