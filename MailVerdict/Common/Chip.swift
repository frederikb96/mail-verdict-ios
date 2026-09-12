import SwiftUI

/// A small rounded label — an account chip on a search or unified row, a state chip ("Retrying",
/// "Error") on an account header, a "Junk" chip on a spam-review row. One shape, every caller
/// supplies its own text and tint rather than each screen rolling its own capsule.
struct Chip: View {
    let text: String
    var tint: Color = .secondary
    var filled: Bool = false

    var body: some View {
        Text(text)
            .font(.caption2.weight(.medium))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .foregroundStyle(filled ? Color.white : tint)
            .background(
                Capsule().fill(filled ? tint : tint.opacity(0.15))
            )
    }
}
