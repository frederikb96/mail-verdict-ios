import MailVerdictKit
import SwiftUI

/// A circle holding a contact photo, or initials on a stable per-identity tint. A unified row
/// adds the contributing account's emoji as a badge at the bottom-trailing corner (UX design §5).
struct AvatarView: View {
    let identity: String
    let displayName: String
    var photo: MVAvatarPhotoSource? = nil
    var unifiedAccountEmoji: String? = nil
    var diameter: CGFloat = 40

    @Environment(\.mvImageLoader) private var imageLoader
    @State private var loadedImage: Image?

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            Group {
                if let loadedImage {
                    loadedImage.resizable().scaledToFill()
                } else {
                    initialsCircle
                }
            }
            .frame(width: diameter, height: diameter)
            .clipShape(Circle())

            if let unifiedAccountEmoji, !unifiedAccountEmoji.isEmpty {
                Text(unifiedAccountEmoji)
                    .font(.system(size: diameter * 0.35))
                    .padding(1)
                    .background(Circle().fill(.background))
            }
        }
        .accessibilityHidden(true)
        .task(id: photo) {
            loadedImage = nil
            guard let photo, let imageLoader else { return }
            loadedImage = await imageLoader.image(for: photo)
        }
    }

    private var initialsCircle: some View {
        let color = MVPalette.avatarColor(for: identity)
        return Circle()
            .fill(color.opacity(0.2))
            .overlay(
                Text(getInitials(displayName))
                    .font(.system(size: diameter * 0.4, weight: .medium))
                    .foregroundStyle(color)
            )
    }
}
