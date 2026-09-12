import Foundation

/// One run of a snippet split on `**bold**` markers — search results render their snippet with
/// the matched terms bold (UX design §2.6); this is the parse, kept separate from rendering
/// (`Text(_:).bold()`, an app-target concern) so it has its own test on Linux.
public struct MVTextSegment: Equatable, Sendable {
    public let text: String
    public let isBold: Bool

    public init(text: String, isBold: Bool) {
        self.text = text
        self.isBold = isBold
    }
}

/// Splits `raw` on `**…**` pairs into alternating plain/bold segments. An unmatched trailing
/// `**` (a snippet truncated mid-marker, which a fixed-length excerpt can genuinely produce) is
/// treated as literal text rather than opening a bold run that never closes.
public func parseBoldMarkers(_ raw: String) -> [MVTextSegment] {
    guard !raw.isEmpty else { return [] }
    var segments: [MVTextSegment] = []
    var remainder = Substring(raw)

    while let firstMarker = remainder.range(of: "**") {
        let beforeBold = remainder[remainder.startIndex..<firstMarker.lowerBound]
        if !beforeBold.isEmpty {
            segments.append(MVTextSegment(text: String(beforeBold), isBold: false))
        }
        let afterFirstMarker = remainder[firstMarker.upperBound...]
        guard let secondMarker = afterFirstMarker.range(of: "**") else {
            // No closing marker — the opening `**` itself is literal text.
            segments.append(MVTextSegment(text: "**", isBold: false))
            remainder = afterFirstMarker
            break
        }
        let bold = afterFirstMarker[afterFirstMarker.startIndex..<secondMarker.lowerBound]
        if !bold.isEmpty {
            segments.append(MVTextSegment(text: String(bold), isBold: true))
        }
        remainder = afterFirstMarker[secondMarker.upperBound...]
    }
    if !remainder.isEmpty {
        segments.append(MVTextSegment(text: String(remainder), isBold: false))
    }
    return segments
}
