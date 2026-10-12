import SwiftUI

/// A small rounded label — an account chip on a search or unified row, a state chip ("Retrying",
/// "Error") on an account header, a "Junk" chip on a spam-review row. One shape, every caller
/// supplies its own text and tint rather than each screen rolling its own capsule.
struct Chip: View {
    let text: String
    var tint: Color = .secondary
    var filled: Bool = false
    /// An SF Symbol after the text, for a chip that clears itself when tapped.
    var trailingSymbol: String?

    var body: some View {
        HStack(spacing: 4) {
            Text(text)
            if let trailingSymbol {
                Image(systemName: trailingSymbol).font(.system(size: 8, weight: .bold))
            }
        }
        .font(.caption2.weight(.medium))
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .foregroundStyle(filled ? Color.white : tint)
        .background(
            Capsule().fill(filled ? tint : tint.opacity(0.15))
        )
    }
}
