import MailVerdictKit
import SwiftUI

/// Says a screen is not live — offline, the server unreachable, or a saved copy on screen. It
/// takes no taps: it sits over content that still must.
struct OfflineCapsule: View {
    let notice: MVOfflineNotice

    var body: some View {
        Label(notice.text, systemImage: MVSymbols.offline)
            .font(.subheadline.weight(.semibold))
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(.regularMaterial, in: Capsule())
            .padding(.top, 8)
            .allowsHitTesting(false)
    }
}
