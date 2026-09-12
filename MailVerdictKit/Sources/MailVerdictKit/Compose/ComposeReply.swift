import Foundation

// Port of the web's `lib/reply.ts`: recipients, subject, threading headers and both halves of a
// quote for reply, reply all and forward.

public enum ComposeReplyMode: Sendable, Equatable {
    case reply, replyAll
}

public struct ComposeReplyDraft: Equatable, Sendable {
    public let to: [String]
    public let cc: [String]
    public let subject: String
    /// The `> `-prefixed plain-text quote appended to the authored text to build `body_text`.
    public let quotedText: String
    /// "On <date>, <name> wrote:" — shown above the quote and the first line of `quotedText`, so
    /// the two forms agree.
    public let attribution: String
    public let inReplyTo: String?
    public let references: [String]?
}

public struct ComposeForwardDraft: Equatable, Sendable {
    public let subject: String
    public let quotedText: String
    public let attribution: String
}

public enum ComposeReply {

    /// `ownAddresses` are left out of a reply-all's Cc: the account's own login address and every
    /// identity it sends as, since a reply to a message that reached one of them should not copy
    /// the person writing it.
    public static func reply(
        to source: MessageDetail, ownAddresses: [String], mode: ComposeReplyMode,
        formatDate: (Date?) -> String = MVDateFormat.fullDate
    ) -> ComposeReplyDraft {
        let senderEmail = extractEmail(source.fromAddr)
        var exclude = Set(ownAddresses.map { extractEmail($0).lowercased() })
        let to = dedupe(senderEmail.isEmpty ? [] : [senderEmail], excluding: [])

        var cc: [String] = []
        if mode == .replyAll {
            let others = ((source.toAddrs?.addresses ?? []) + (source.ccAddrs?.addresses ?? [])).map(extractEmail)
            exclude.insert(senderEmail.lowercased())
            cc = dedupe(others, excluding: exclude)
        }

        var references = source.references ?? []
        if let messageId = source.messageId { references.append(messageId) }

        let attribution = "On \(formatDate(source.receivedAt)), \(extractSenderName(source.fromAddr)) wrote:"
        let base = source.subject ?? "(no subject)"
        return ComposeReplyDraft(
            to: to, cc: cc, subject: base.lowercased().hasPrefix("re:") ? base : "Re: \(base)",
            quotedText: quotedPlainText(body: source.bodyText, attribution: attribution), attribution: attribution,
            inReplyTo: source.messageId, references: references.isEmpty ? nil : references)
    }

    /// No In-Reply-To or References: a forward goes to someone new and starts its own thread.
    public static func forward(
        _ source: MessageDetail, formatDate: (Date?) -> String = MVDateFormat.fullDate
    ) -> ComposeForwardDraft {
        let base = source.subject ?? "(no subject)"
        let lowered = base.lowercased()
        let subject = lowered.hasPrefix("fwd:") || lowered.hasPrefix("fw:") ? base : "Fwd: \(base)"
        let attribution = [
            "---------- Forwarded message ----------",
            "From: \(source.fromAddr ?? "unknown")",
            "Date: \(formatDate(source.receivedAt))",
            "Subject: \(source.subject ?? "(no subject)")",
            "To: \((source.toAddrs?.addresses ?? []).joined(separator: ", "))",
        ].joined(separator: "\n")
        return ComposeForwardDraft(
            subject: subject, quotedText: quotedPlainText(body: source.bodyText, attribution: attribution),
            attribution: attribution)
    }

    /// The plain-text quote of a reopened draft. There is no original message to build it from —
    /// only the draft's own `body_text`, where the attribution line marks exactly where the quote
    /// began when the draft was saved.
    public static func draftQuotedText(bodyText: String?, attribution: String) -> String {
        guard let bodyText, !attribution.isEmpty else { return "" }
        guard let range = bodyText.range(of: "\n\n\(attribution)") else { return "" }
        return String(bodyText[range.lowerBound...])
    }

    /// The plain-text quote rebuilt from the quote's HTML — for a cancelled send, whose staged
    /// row keeps the HTML body but not the text one.
    public static func quotedPlainText(from quote: ComposeQuote) -> String {
        let body = ComposeHTMLParser.parse(quote.html).document.blocks.map(\.plainText).joined(separator: "\n")
        return quotedPlainText(body: body, attribution: quote.attribution)
    }

    static func quotedPlainText(body: String?, attribution: String) -> String {
        let quoted = (body ?? "").components(separatedBy: "\n").map { "> \($0)" }.joined(separator: "\n")
        return "\n\n\(attribution)\n\(quoted)"
    }

    /// Case-insensitive, first occurrence wins, empty entries dropped.
    static func dedupe(_ addresses: [String], excluding exclude: Set<String>) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for address in addresses {
            let key = address.lowercased()
            if address.isEmpty || seen.contains(key) || exclude.contains(key) { continue }
            seen.insert(key)
            result.append(address)
        }
        return result
    }
}
