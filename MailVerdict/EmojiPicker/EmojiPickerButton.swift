import MailVerdictKit
import SwiftUI

/// A small button showing the current emoji (or a placeholder) that presents the shared emoji
/// grid in a popover — used by a unified view row and an account's icon alike, per the UX
/// design's "EmojiPicker is shared with the account cards".
struct EmojiPickerButton: View {
    let currentEmoji: String?
    let accessibilityLabel: String
    let onSelect: (String?) -> Void

    @State private var isPresented = false

    var body: some View {
        Button {
            isPresented = true
        } label: {
            Text(currentEmoji ?? "➕")
                .font(.title3)
                .frame(width: 32, height: 32)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(accessibilityLabel))
        .popover(isPresented: $isPresented) {
            EmojiPickerGrid(currentEmoji: currentEmoji) { emoji in
                onSelect(emoji)
                isPresented = false
            }
            .frame(minWidth: 280, minHeight: 220)
        }
    }
}

/// The 35-emoji grid plus "clear" — split out from the button so a full-screen picker (the
/// Unified Views screen's own sheet) can present the same grid without the button chrome.
struct EmojiPickerGrid: View {
    let currentEmoji: String?
    let onSelect: (String?) -> Void

    private let columns = Array(repeating: GridItem(.flexible()), count: 7)

    var body: some View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: 10) {
                if currentEmoji != nil {
                    Button {
                        onSelect(nil)
                    } label: {
                        Image(systemName: "xmark.circle")
                            .font(.title3)
                            .foregroundStyle(.secondary)
                    }
                    .accessibilityLabel(Text("Clear emoji"))
                }
                ForEach(MVEmojiPalette.emojis, id: \.self) { emoji in
                    Button {
                        onSelect(emoji)
                    } label: {
                        Text(emoji).font(.title3)
                    }
                }
            }
            .padding()
        }
    }
}
