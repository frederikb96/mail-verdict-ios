import Foundation

/// One reader page's conversation: every message of the opened row's thread, oldest first as the
/// API sends them.
public struct ReaderConversation: Sendable, Equatable {
    public var messages: [MessageDetail]
    /// The row's own message — the one opened, and the one every action targets.
    public var openedId: UUID

    public init(messages: [MessageDetail], openedId: UUID) {
        self.messages = messages
        self.openedId = openedId
    }

    public var primary: MessageDetail? {
        messages.first { $0.id == openedId } ?? messages.last
    }

    public var messageIds: [UUID] {
        messages.map(\.id)
    }
}

/// Per-page inputs beyond the conversation itself.
public struct ReaderDocumentOptions: Sendable, Equatable {
    public var theme: MVCanvas
    public var canvasChoices: [UUID: MVCanvas]
    /// A rendered invitation card (`InvitationCardBuilder`) per message, once its invitation loaded.
    public var invitationCards: [UUID: String]
    /// Lower-cased sender address → avatar image URL.
    public var avatarSources: [String: String]
    /// Messages shown expanded; `nil` means only the opened one, as on the web.
    public var expandedIds: Set<UUID>?
    public var now: Date

    public init(
        theme: MVCanvas, canvasChoices: [UUID: MVCanvas] = [:], invitationCards: [UUID: String] = [:],
        avatarSources: [String: String] = [:], expandedIds: Set<UUID>? = nil, now: Date = Date()
    ) {
        self.theme = theme
        self.canvasChoices = canvasChoices
        self.invitationCards = invitationCards
        self.avatarSources = avatarSources
        self.expandedIds = expandedIds
        self.now = now
    }
}

/// Builds a reader page: the whole conversation as one HTML document — port of the web's
/// `reading-pane.tsx` and `thread-message.tsx` layout, drawn to read as native chrome.
///
/// Newest message first; every message but the opened one starts collapsed. Each message is a
/// `<details>` element, so expanding and collapsing needs no script, and a tap on a link inside
/// the header (an address) never folds it. Each body sits in its own open declarative shadow
/// root, which isolates the message's CSS from the chrome and from other messages with no script
/// either.
public enum ConversationDocumentBuilder {

    public static func messageElementId(_ id: UUID) -> String { "mv-msg-\(id.uuidString.lowercased())" }
    public static func contentElementId(_ id: UUID) -> String { "mv-content-\(id.uuidString.lowercased())" }
    public static func bodyElementId(_ id: UUID) -> String { "mv-body-\(id.uuidString.lowercased())" }

    static let calendarContentTypes: Set<String> = ["text/calendar", "application/ics"]

    public static func hasCalendarAttachment(_ message: MessageDetail) -> Bool {
        message.attachments.contains { calendarContentTypes.contains($0.contentType?.lowercased() ?? "") }
    }

    public static func rendering(for message: MessageDetail, options: ReaderDocumentOptions) -> MessageBodyRendering {
        MessageBodyRenderer.render(
            bodyHTML: message.bodyHtml, bodyText: message.bodyText, theme: options.theme,
            manualCanvas: options.canvasChoices[message.id])
    }

    // MARK: Documents

    public static func document(for conversation: ReaderConversation, options: ReaderDocumentOptions) -> String {
        guard let primary = conversation.primary else {
            return errorDocument(message: "Message not found", theme: options.theme)
        }
        let expanded = options.expandedIds ?? [primary.id]
        let rows = conversation.messages.reversed().map { message in
            messageBlock(
                message, expanded: expanded.contains(message.id), isPrimary: message.id == primary.id, options: options)
        }
        let subject = escape(primary.subject?.isEmpty == false ? primary.subject! : "(no subject)")
        let body =
            #"<h1 class="mv-subject">\#(subject)</h1><div class="mv-thread">\#(rows.joined())</div>"#
        return page(body: body, theme: options.theme, primaryId: primary.id)
    }

    public static func loadingDocument(theme: MVCanvas) -> String {
        let bars = [70, 45, 30, 100, 100, 85, 60].map { #"<div class="mv-skeleton" style="width: \#($0)%"></div>"# }
        return page(body: #"<div class="mv-loading">\#(bars.joined())</div>"#, theme: theme, primaryId: nil)
    }

    public static func errorDocument(message: String, theme: MVCanvas) -> String {
        let body =
            #"<div class="mv-error"><p class="mv-error-title">Something went wrong</p><p>\#(escape(message))</p>"#
            + #"<a class="mv-btn mv-btn-primary" href="\#(MVReaderLink.retry.url)">Try Again</a></div>"#
        return page(body: body, theme: theme, primaryId: nil)
    }

    private static func page(body: String, theme: MVCanvas, primaryId: UUID?) -> String {
        let primary = primaryId.map { #" data-primary="\#($0.uuidString.lowercased())""# } ?? ""
        return """
            <!doctype html><html class="theme-\(theme.rawValue)"\(primary)><head><meta charset="utf-8">\
            <meta name="viewport" content="width=device-width, initial-scale=1, minimum-scale=1, maximum-scale=5">\
            <style>\(chromeCSS)\(InvitationCardBuilder.css)</style></head><body>\(body)</body></html>
            """
    }

    // MARK: Messages

    static func messageBlock(
        _ message: MessageDetail, expanded: Bool, isPrimary: Bool, options: ReaderDocumentOptions
    ) -> String {
        let id = messageElementId(message.id)
        if message.isDraft && !isPrimary {
            return
                #"<a class="mv-message mv-draft-row" id="\#(id)" href="\#(MVReaderLink.draft(messageId: message.id).url)">"#
                + collapsedRow(message, options: options, isDraft: true) + "</a>"
        }
        let open = expanded ? " open" : ""
        return #"<details class="mv-message" id="\#(id)"\#(open)><summary class="mv-summary">"#
            + collapsedRow(message, options: options, isDraft: false)
            + expandedHeader(message, isPrimary: isPrimary, options: options)
            + "</summary>" + content(message, options: options) + "</details>"
    }

    static func collapsedRow(_ message: MessageDetail, options: ReaderDocumentOptions, isDraft: Bool) -> String {
        let sender = extractSenderName(message.fromAddr)
        let weight = message.isSeen ? "" : " mv-unread"
        let draft = isDraft ? #"<span class="mv-chip mv-chip-draft">Draft</span>"# : ""
        let pending = message.pendingSync ? #"<span class="mv-spinner"></span>"# : ""
        return #"<div class="mv-collapsed">\#(avatar(message, options: options, size: 28))"#
            + #"<span class="mv-sender\#(weight)">\#(escape(sender))</span>\#(draft)\#(pending)"#
            + #"<span class="mv-snippet">\#(escape(message.snippet ?? ""))</span>"#
            + #"<span class="mv-date">\#(escape(MVDateFormat.relativeDate(message.receivedAt, now: options.now)))</span></div>"#
    }

    static func expandedHeader(_ message: MessageDetail, isPrimary: Bool, options: ReaderDocumentOptions) -> String {
        let sender = extractSenderName(message.fromAddr)
        let email = extractEmail(message.fromAddr)
        let from =
            #"<a class="mv-addr mv-from" href="\#(MVReaderLink.address(messageId: message.id, field: .from, index: 0).url)">"#
            + #"<span class="mv-from-name">\#(escape(sender))</span> <span class="mv-email">&lt;\#(escape(email))&gt;</span></a>"#
        let clip = message.attachments.isEmpty ? "" : paperclip
        let pending = message.pendingSync ? #"<span class="mv-spinner"></span>"# : ""
        let openControl =
            isPrimary
            ? ""
            : #"<a class="mv-open-btn" aria-label="Open this message" href="\#(MVReaderLink.openMessage(messageId: message.id).url)">\#(locateGlyph)</a>"#
        return #"<div class="mv-expanded">\#(avatar(message, options: options, size: 40))<div class="mv-header-text">"#
            + from
            + recipientLine("To:", field: .to, addresses: message.toAddrs?.addresses ?? [], messageId: message.id)
            + recipientLine("Cc:", field: .cc, addresses: message.ccAddrs?.addresses ?? [], messageId: message.id)
            + #"<div class="mv-full-date">\#(escape(MVDateFormat.fullDate(message.receivedAt)))\#(clip)\#(pending)\#(openControl)</div>"#
            + "</div>" + chevronDown + "</div>"
    }

    static func recipientLine(
        _ label: String, field: MVReaderLink.AddressField, addresses: [String], messageId: UUID
    ) -> String {
        guard !addresses.isEmpty else { return "" }
        let links = addresses.enumerated().map { index, address in
            #"<a class="mv-addr" href="\#(MVReaderLink.address(messageId: messageId, field: field, index: index).url)">\#(escape(address))</a>"#
        }
        return
            #"<div class="mv-recipients"><span class="mv-label">\#(label)</span> \#(links.joined(separator: ", "))</div>"#
    }

    /// The expandable part of a message, one block `ReaderSession` swaps whole when the message
    /// changes underneath the page (a verdict arriving, images allowed).
    public static func content(_ message: MessageDetail, options: ReaderDocumentOptions) -> String {
        var parts: [String] = []
        if let verdict = message.verdict {
            let chip =
                verdict.isSpam
                ? #"<span class="mv-chip mv-chip-spam">Flagged as spam</span>"#
                : #"<span class="mv-chip mv-chip-outline">Not spam</span>"#
            parts.append(#"<div class="mv-verdict">\#(chip)<span>\#(escape(verdict.reasoning ?? ""))</span></div>"#)
        }
        if hasCalendarAttachment(message) {
            parts.append(options.invitationCards[message.id] ?? InvitationCardBuilder.emptySlot(messageId: message.id))
        }
        if message.isTruncated {
            parts.append(
                #"<div class="mv-banner mv-banner-muted">This message is too large to display. Its content was not downloaded during sync.</div>"#
            )
        } else {
            if message.hasBlockedImages && !message.imagesAllowed {
                parts.append(imageBanner(message))
            }
            parts.append(bodyHost(message.id, rendering: rendering(for: message, options: options)))
        }
        if !message.attachments.isEmpty {
            parts.append(attachments(message))
        }
        return #"<div class="mv-content" id="\#(contentElementId(message.id))">\#(parts.joined())</div>"#
    }

    public static func bodyHost(_ messageId: UUID, rendering: MessageBodyRendering) -> String {
        #"<div class="mv-body" id="\#(bodyElementId(messageId))"><template shadowrootmode="open">"#
            + rendering.shadowContent + "</template></div>"
    }

    static func imageBanner(_ message: MessageDetail) -> String {
        let email = extractEmail(message.fromAddr)
        let domain = email.split(separator: "@").dropFirst().first.map(String.init)
        var buttons = [imageButton("Load for this message", message.id, .once)]
        if !email.isEmpty { buttons.append(imageButton("Always from \(email)", message.id, .sender)) }
        if let domain { buttons.append(imageButton("Always from @\(domain)", message.id, .domain)) }
        return #"<div class="mv-banner mv-banner-amber"><div>Remote images blocked for privacy</div>"#
            + #"<div class="mv-banner-actions">\#(buttons.joined())</div></div>"#
    }

    private static func imageButton(_ label: String, _ id: UUID, _ choice: MVReaderLink.ImageChoice) -> String {
        #"<a class="mv-banner-button" href="\#(MVReaderLink.images(messageId: id, choice: choice).url)">\#(escape(label))</a>"#
    }

    static func attachments(_ message: MessageDetail) -> String {
        let count = message.attachments.count
        let tiles = message.attachments.map { attachment in
            let name = attachment.filename ?? "Attachment"
            let size = attachment.sizeBytes.map { #"<span class="mv-file-size">\#(formatSize($0))</span>"# } ?? ""
            return #"<div class="mv-attachment">"#
                + #"<a class="mv-attachment-open" href="\#(MVReaderLink.attachment(messageId: message.id, attachmentId: attachment.id).url)">"#
                + #"<span class="mv-file-badge">\#(escape(fileBadge(attachment)))</span>"#
                + #"<span class="mv-file-text"><span class="mv-file-name">\#(escape(name))</span>\#(size)</span></a>"#
                + #"<a class="mv-attachment-share" aria-label="Share" href="\#(MVReaderLink.shareAttachment(messageId: message.id, attachmentId: attachment.id).url)">\#(shareGlyph)</a>"#
                + "</div>"
        }
        return
            #"<div class="mv-attachments"><div class="mv-attachments-title">\#(paperclip)\#(count) attachment\#(count == 1 ? "" : "s")</div>"#
            + tiles.joined() + "</div>"
    }

    /// A short type label for a tile — the file's extension, else the MIME subtype.
    static func fileBadge(_ attachment: AttachmentSummary) -> String {
        if let name = attachment.filename, let dot = name.lastIndex(of: "."), name.index(after: dot) < name.endIndex {
            let ext = name[name.index(after: dot)...]
            if ext.count <= 4 { return ext.uppercased() }
        }
        if let subtype = attachment.contentType?.split(separator: "/").last, subtype.count <= 4 {
            return subtype.uppercased()
        }
        return "FILE"
    }

    static func avatar(_ message: MessageDetail, options: ReaderDocumentOptions, size: Int) -> String {
        let name = extractSenderName(message.fromAddr)
        let email = extractEmail(message.fromAddr)
        let color = avatarColorHex(for: email.isEmpty ? name : email)
        var style = "--avatar: \(color); width: \(size)px; height: \(size)px; font-size: \(size * 2 / 5)px"
        if let source = options.avatarSources[email.lowercased()] {
            style += "; background-image: url('\(cssURL(source))')"
        }
        return #"<span class="mv-avatar" style="\#(escape(style))">\#(escape(getInitials(name)))</span>"#
    }

    private static func cssURL(_ url: String) -> String {
        url.replacingOccurrences(of: "\\", with: "%5C").replacingOccurrences(of: "'", with: "%27")
            .replacingOccurrences(of: ")", with: "%29").replacingOccurrences(of: "\n", with: "")
    }

    private static func escape(_ text: String) -> String {
        PlainTextLinkifier.escapeHTML(text)
    }

    // MARK: Glyphs and styles

    static let paperclip =
        #"<svg class="mv-glyph" viewBox="0 0 24 24" aria-hidden="true"><path d="M20 11.5l-8.2 8.2a5 5 0 0 1-7.1-7.1l8.5-8.5a3.3 3.3 0 0 1 4.7 4.7l-8.5 8.5a1.7 1.7 0 0 1-2.4-2.4l7.8-7.8"/></svg>"#
    static let chevronDown =
        #"<svg class="mv-glyph mv-chevron" viewBox="0 0 24 24" aria-hidden="true"><path d="M6 9l6 6 6-6"/></svg>"#
    static let shareGlyph =
        #"<svg class="mv-glyph" viewBox="0 0 24 24" aria-hidden="true"><path d="M12 3v12M7.5 7.5L12 3l4.5 4.5M5 11v8a2 2 0 0 0 2 2h10a2 2 0 0 0 2-2v-8"/></svg>"#
    static let locateGlyph =
        #"<svg class="mv-glyph" viewBox="0 0 24 24" aria-hidden="true"><circle cx="12" cy="12" r="3"/><path d="M12 2v4M12 18v4M2 12h4M18 12h4"/></svg>"#

    /// The chrome's own stylesheet — iOS system colours per theme, Dynamic Type text styles, and
    /// `overflow-x: hidden` at the root so that at rest zoom the page never scrolls sideways and
    /// every horizontal drag belongs to the pager.
    static let chromeCSS = """
        :root.theme-light { color-scheme: light; --bg: #ffffff; --label: #000000; --secondary: rgba(60,60,67,.6);
          --separator: rgba(60,60,67,.29); --fill: rgba(120,120,128,.08); --fill-strong: rgba(120,120,128,.16);
          --tint: #007aff; --destructive: #ff3b30; --amber-bg: rgba(245,158,11,.1); --amber-border: rgba(245,158,11,.4);
          --amber-text: #b45309; --unread: #0ea5e9; }
        :root.theme-dark { color-scheme: dark; --bg: #000000; --label: #ffffff; --secondary: rgba(235,235,245,.6);
          --separator: rgba(84,84,88,.65); --fill: rgba(120,120,128,.18); --fill-strong: rgba(120,120,128,.32);
          --tint: #0a84ff; --destructive: #ff453a; --amber-bg: rgba(251,191,36,.1); --amber-border: rgba(251,191,36,.4);
          --amber-text: #fbbf24; --unread: #38bdf8; }
        html, body { overflow-x: hidden; }
        html { -webkit-text-size-adjust: 100%; -webkit-tap-highlight-color: transparent; }
        body { margin: 0; background: var(--bg); color: var(--label); font: -apple-system-body; }
        a { color: var(--tint); }
        .mv-subject { font: -apple-system-title2; font-weight: 700; margin: 12px 16px 8px; overflow-wrap: anywhere; }
        .mv-message { display: block; border-bottom: 0.5px solid var(--separator); color: inherit; text-decoration: none; }
        .mv-summary { list-style: none; display: block; padding: 10px 16px; }
        .mv-summary::-webkit-details-marker { display: none; }
        details[open] > .mv-summary .mv-collapsed, details:not([open]) > .mv-summary .mv-expanded { display: none; }
        .mv-collapsed { display: flex; align-items: center; gap: 10px; min-height: 36px; }
        .mv-draft-row .mv-collapsed { padding: 10px 16px; }
        .mv-sender { font-weight: 500; white-space: nowrap; }
        .mv-sender.mv-unread { font-weight: 700; }
        .mv-snippet { flex: 1; min-width: 0; color: var(--secondary); white-space: nowrap; overflow: hidden;
          text-overflow: ellipsis; font: -apple-system-subheadline; }
        .mv-date { color: var(--secondary); font: -apple-system-footnote; white-space: nowrap; }
        .mv-expanded { display: flex; align-items: flex-start; gap: 10px; }
        .mv-header-text { flex: 1; min-width: 0; display: flex; flex-direction: column; gap: 2px; }
        .mv-addr { color: inherit; text-decoration: none; overflow-wrap: anywhere; }
        .mv-from-name { font: -apple-system-headline; }
        .mv-email, .mv-recipients, .mv-full-date { color: var(--secondary); font: -apple-system-subheadline; }
        .mv-recipients .mv-addr { color: var(--secondary); }
        .mv-full-date { display: flex; align-items: center; gap: 6px; }
        .mv-open-btn { color: var(--tint); padding: 4px; margin: -4px; display: inline-flex; }
        .mv-avatar { flex: none; border-radius: 50%; display: inline-flex; align-items: center; justify-content: center;
          color: var(--avatar); background-color: color-mix(in srgb, var(--avatar) 20%, transparent);
          background-size: cover; background-position: center; font-weight: 600; overflow: hidden; }
        .mv-chip { font: -apple-system-caption1; font-weight: 600; padding: 2px 8px; border-radius: 10px; white-space: nowrap; }
        .mv-chip-spam { background: var(--destructive); color: #fff; }
        .mv-chip-outline { border: 1px solid var(--separator); color: var(--secondary); }
        .mv-chip-draft { background: var(--fill-strong); color: var(--destructive); }
        .mv-verdict { display: flex; gap: 8px; align-items: baseline; padding: 0 16px 10px; color: var(--secondary);
          font: -apple-system-footnote; }
        .mv-banner { margin: 0 16px 10px; padding: 10px 12px; border-radius: 10px; font: -apple-system-subheadline; }
        .mv-banner-muted { background: var(--fill); color: var(--secondary); }
        .mv-banner-amber { background: var(--amber-bg); color: var(--amber-text); display: flex; flex-direction: column; gap: 8px; }
        .mv-banner-actions { display: flex; flex-wrap: wrap; gap: 6px; }
        .mv-banner-button { color: var(--amber-text); border: 1px solid var(--amber-border); border-radius: 14px;
          padding: 4px 10px; text-decoration: none; font: -apple-system-footnote; }
        .mv-body { padding: 8px 16px; }
        .mv-attachments { padding: 8px 16px 14px; display: flex; flex-direction: column; gap: 8px; }
        .mv-attachments-title { display: flex; align-items: center; gap: 6px; font: -apple-system-subheadline; font-weight: 600; }
        .mv-attachment { display: flex; align-items: center; gap: 8px; background: var(--fill); border-radius: 12px; padding: 8px 12px; }
        .mv-attachment-open { flex: 1; min-width: 0; display: flex; align-items: center; gap: 10px; color: inherit; text-decoration: none; }
        .mv-file-badge { flex: none; min-width: 36px; height: 36px; border-radius: 8px; background: var(--tint); color: #fff;
          display: inline-flex; align-items: center; justify-content: center; font: -apple-system-caption2; font-weight: 700; }
        .mv-file-text { display: flex; flex-direction: column; min-width: 0; }
        .mv-file-name { white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }
        .mv-file-size { color: var(--secondary); font: -apple-system-footnote; }
        .mv-attachment-share { color: var(--tint); padding: 6px; }
        .mv-glyph { width: 16px; height: 16px; flex: none; fill: none; stroke: currentColor; stroke-width: 2;
          stroke-linecap: round; stroke-linejoin: round; }
        .mv-chevron { color: var(--secondary); margin-top: 4px; }
        .mv-loading { padding: 20px 16px; display: flex; flex-direction: column; gap: 12px; }
        .mv-skeleton { height: 14px; border-radius: 7px; background: var(--fill-strong); animation: mv-pulse 1.4s ease-in-out infinite; }
        @keyframes mv-pulse { 50% { opacity: .45; } }
        .mv-error { padding: 80px 32px; text-align: center; color: var(--secondary); display: flex; flex-direction: column;
          align-items: center; gap: 8px; }
        .mv-error-title { color: var(--label); font: -apple-system-headline; margin: 0; }
        """
}
