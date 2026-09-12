import Foundation

/// A parsed `mailto:` link — port of the web's `lib/mailto.ts` `MailtoIntent`/`parseMailto`.
/// Every failure returns `nil` rather than a half-filled intent: a composer that opens with the
/// recipient silently missing is worse than one that opens blank.
public struct MailtoLink: Hashable, Sendable {
    public let to: [String]
    public let cc: [String]
    public let bcc: [String]
    public let subject: String?
    /// The `body` parameter, already turned into paragraph HTML for the editor.
    public let bodyHtml: String?

    public init(
        to: [String] = [], cc: [String] = [], bcc: [String] = [], subject: String? = nil, bodyHtml: String? = nil
    ) {
        self.to = to
        self.cc = cc
        self.bcc = bcc
        self.subject = subject
        self.bodyHtml = bodyHtml
    }
}

/// Parses a `mailto:` URL. `decodeURIComponent` throwing on a stray `%` in the web port became,
/// here, a decode that passes the raw value through unchanged on failure — same reasoning
/// (surviving a malformed link matters more than rejecting it), different mechanism.
public func parseMailto(_ raw: String) -> MailtoLink? {
    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    guard trimmed.lowercased().hasPrefix("mailto:") else { return nil }

    let rest = String(trimmed.dropFirst("mailto:".count))
    let path: Substring
    let queryString: Substring
    if let questionMark = rest.firstIndex(of: "?") {
        path = rest[..<questionMark]
        queryString = rest[rest.index(after: questionMark)...]
    } else {
        path = rest[...]
        queryString = ""
    }

    let query = parseQueryItems(String(queryString))

    // A parameter may repeat and may also duplicate the path recipients; the union is what the
    // sender meant, so recipients are merged and de-duplicated rather than one source winning.
    var to = addresses(String(path))
    to.append(contentsOf: addresses(query["to"]))
    var seen = Set<String>()
    let dedupedTo = to.filter { seen.insert($0).inserted }

    let cc = addresses(query["cc"])
    let bcc = addresses(query["bcc"])
    let subject = query["subject"].flatMap { $0.isEmpty ? nil : $0 }
    let body = query["body"]
    let bodyHtml = body.flatMap { $0.isEmpty ? nil : textToHTML($0) }

    guard !dedupedTo.isEmpty || !cc.isEmpty || !bcc.isEmpty || subject != nil || bodyHtml != nil else {
        return nil
    }
    return MailtoLink(to: dedupedTo, cc: cc, bcc: bcc, subject: subject, bodyHtml: bodyHtml)
}

/// Addresses arrive comma-separated and percent-encoded, and a trailing or doubled comma is
/// common enough in real links to be worth surviving.
private func addresses(_ value: String?) -> [String] {
    guard let value, !value.isEmpty else { return [] }
    return value.split(separator: ",", omittingEmptySubsequences: true)
        .map { decodeLenient(String($0).trimmingCharacters(in: .whitespaces)) }
        .filter { !$0.isEmpty }
}

private func decodeLenient(_ value: String) -> String {
    value.removingPercentEncoding ?? value
}

private func parseQueryItems(_ query: String) -> [String: String] {
    guard !query.isEmpty else { return [:] }
    var result: [String: String] = [:]
    for pair in query.split(separator: "&") {
        let parts = pair.split(separator: "=", maxSplits: 1)
        guard let rawKey = parts.first else { continue }
        let key = decodeLenient(String(rawKey))
        let value = parts.count > 1 ? decodeLenient(String(parts[1])) : ""
        result[key] = value
    }
    return result
}

private func escapeHTML(_ value: String) -> String {
    value.replacingOccurrences(of: "&", with: "&amp;")
        .replacingOccurrences(of: "<", with: "&lt;")
        .replacingOccurrences(of: ">", with: "&gt;")
}

/// Plain text to the paragraph markup the editor expects. A blank line separates paragraphs; a
/// single newline is a line break inside one.
private func textToHTML(_ value: String) -> String {
    value.components(separatedBy: "\n\n")
        .map { block in
            "<p>\(escapeHTML(block).replacingOccurrences(of: "\n", with: "<br>"))</p>"
        }
        .joined()
}

/// A composer sheet's one presentation state — never a pushed `Route`: a dirty composer blocks
/// navigation by being modal, the native replacement for the web's own "dirty composer blocks
/// navigation" guard.
public struct ComposeIntent: Identifiable, Hashable, Sendable {
    public enum Kind: Hashable, Sendable {
        case new(accountId: UUID?)
        case reply(messageId: UUID)
        case replyAll(messageId: UUID)
        case forward(messageId: UUID)
        case draft(messageId: UUID)
        case mailto(MailtoLink)
        /// Undo Send reopening the composer it cancelled — `pendingSendId` is what
        /// `MVApiClient.cancelPendingSend` and the attachment refetch both key on.
        case undoRestore(pendingSendId: UUID)
    }

    public let id: UUID
    public let kind: Kind

    public init(id: UUID = UUID(), kind: Kind) {
        self.id = id
        self.kind = kind
    }
}
