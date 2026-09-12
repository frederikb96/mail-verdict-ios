import Foundation

/// Ports of `ui/src/lib/format.ts`'s sender/address helpers.

private let senderNameRegex = try! NSRegularExpression(pattern: #"^"?([^"<]+)"?\s*<.*>$"#)

/// Extracts a sender display name from a `"Name <email@example.com>"` or bare-address string.
public func extractSenderName(_ from: String?) -> String {
    guard let from, !from.isEmpty else { return "Unknown" }
    let range = NSRange(from.startIndex..., in: from)
    if let match = senderNameRegex.firstMatch(in: from, range: range), match.numberOfRanges > 1,
        let groupRange = Range(match.range(at: 1), in: from)
    {
        return String(from[groupRange]).trimmingCharacters(in: .whitespaces)
    }
    return String(from.split(separator: "@").first ?? Substring(from))
}

/// Extracts the bare email address from a `"Name <email@example.com>"` string, or returns the
/// input unchanged if it carries no angle brackets.
public func extractEmail(_ from: String?) -> String {
    guard let from else { return "" }
    if let open = from.firstIndex(of: "<"), let close = from.firstIndex(of: ">"), open < close {
        return String(from[from.index(after: open)..<close])
    }
    return from
}

/// 1-2 letter initials from a name — the first and last word's first letter for a multi-word
/// name, or the first two characters otherwise.
public func getInitials(_ name: String) -> String {
    let parts = name.trimmingCharacters(in: .whitespaces).split(separator: " ").filter { !$0.isEmpty }
    if parts.count >= 2, let first = parts.first?.first, let last = parts.last?.first {
        return String([first, last]).uppercased()
    }
    return String(name.trimmingCharacters(in: .whitespaces).prefix(2)).uppercased()
}

/// A recipient line for a search result row: full addresses (never just display names, which
/// are ambiguous the moment two of the reader's own addresses share one), joined and truncated
/// to a small fixed count with a "+N more" tail. `nil` for a genuinely to-less message.
public func formatRecipientList(_ addrs: [String]?, maxShown: Int = 3) -> String? {
    guard let addrs, !addrs.isEmpty else { return nil }
    let emails = addrs.map(extractEmail)
    if emails.count <= maxShown { return emails.joined(separator: ", ") }
    return emails.prefix(maxShown).joined(separator: ", ") + " +\(emails.count - maxShown) more"
}

/// Parses a comma/semicolon-separated address field into a list. Does not validate each address
/// — a caller turning free text into recipients checks each with `isValidEmail` before sending,
/// since a send that never leaves reports its failure much later than the field it was typed into.
public func parseAddressList(_ value: String) -> [String] {
    value.split(whereSeparator: { $0 == "," || $0 == ";" })
        .map { $0.trimmingCharacters(in: .whitespaces) }
        .filter { !$0.isEmpty }
}

/// A permissive shape check — one `@` with something on each side, no whitespace — not full RFC
/// 5322 validation. Good enough to catch a plain word typed and committed by mistake.
public func isValidEmail(_ address: String) -> Bool {
    address.range(of: #"^[^\s@]+@[^\s@]+\.[^\s@]+$"#, options: .regularExpression) != nil
}

/// A stable colour for an initials avatar, derived from the identity it represents (an email
/// address where one is available, a display name otherwise) — the same sender always lands on
/// the same colour. Returns a hex string rather than a platform colour type, since this package
/// also builds on Linux; `Theme/MVPalette.swift` (guarded by `canImport(SwiftUI)`) turns it into
/// a `Color`.
public func avatarColorHex(for identity: String) -> String {
    MVAvatarPalette.colors[djb2(identity) % MVAvatarPalette.colors.count]
}

enum MVAvatarPalette {
    static let colors = [
        "#3b82f6", "#22c55e", "#f97316", "#a855f7", "#ec4899", "#14b8a6",
        "#eab308", "#ef4444", "#6366f1", "#84cc16", "#06b6d4", "#f43f5e",
    ]
}

private func djb2(_ value: String) -> Int {
    var hash: Int32 = 5381
    for scalar in value.unicodeScalars {
        hash = 33 &* hash &+ Int32(scalar.value)
    }
    return abs(Int(hash))
}
