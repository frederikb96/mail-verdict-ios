import Foundation

extension OrderFactOut {
    /// What opens when the fact is tapped: the server-built tracking page, or the link itself --
    /// only ever a web address, so a value that merely looks like a link opens nothing.
    public var linkURL: URL? {
        let candidate: String?
        switch kind {
        case .trackingNumber: candidate = trackingUrl
        case .link: candidate = value
        default: candidate = nil
        }
        guard let candidate,
            let url = URL(string: candidate.trimmingCharacters(in: .whitespacesAndNewlines)),
            let scheme = url.scheme?.lowercased(), scheme == "https" || scheme == "http",
            url.host?.isEmpty == false
        else { return nil }
        return url
    }

    /// The label to show: the model's own, or the kind's plain name when it left it out.
    public var displayLabel: String {
        let trimmed = label.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? kind.defaultLabel : trimmed
    }

    /// What copying the fact puts on the pasteboard: the value, or the printable payload of a code
    /// whose value the model left empty.
    public var copyText: String? {
        if !value.isEmpty { return value }
        return code?.payloadText
    }
}

extension OrderFactKind {
    public var defaultLabel: String {
        switch self {
        case .orderNumber: return "Order"
        case .bookingCode: return "Booking"
        case .ticketNumber: return "Ticket"
        case .invoiceNumber: return "Invoice"
        case .trackingNumber: return "Tracking"
        case .date: return "Date"
        case .time: return "Time"
        case .amount: return "Amount"
        case .place: return "Place"
        case .seat: return "Seat"
        case .person: return "Person"
        case .code: return "Code"
        case .link: return "Link"
        case .other: return "Detail"
        }
    }
}

extension OrderDetail {
    /// The facts that carry a scannable code, in display order.
    public var codeFacts: [OrderFactOut] { facts.filter { $0.code != nil } }

    /// Everything but the codes, which draw as thumbnails of their own.
    public var detailFacts: [OrderFactOut] { facts.filter { $0.code == nil } }
}
