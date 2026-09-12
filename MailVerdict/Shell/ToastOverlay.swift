import MailVerdictKit
import SwiftUI

/// The root toast host — a floating glass capsule above the bottom bar. Reads `MVToastStore` and
/// renders whatever it currently holds; it never decides what shows, only how.
struct ToastOverlay: View {
    let store: MVToastStore

    var body: some View {
        VStack {
            Spacer()
            if let toast = store.current {
                capsule(for: toast)
                    .padding(.bottom, 8)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.default, value: store.current?.id)
        .allowsHitTesting(store.current != nil)
    }

    private func capsule(for toast: MVToast) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon(for: toast.variant))
                .foregroundStyle(color(for: toast.variant))
            Text(toast.message)
                .font(.subheadline)
                .lineLimit(2)
            if let title = toast.actionTitle, let action = toast.action {
                Button(title) {
                    action()
                    store.dismiss(id: toast.id)
                }
                .font(.subheadline.weight(.semibold))
            }
            if toast.duration == 0 {
                Button {
                    store.dismiss(id: toast.id)
                } label: {
                    Image(systemName: "xmark")
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.thinMaterial, in: Capsule())
        .shadow(radius: 8)
        .padding(.horizontal)
    }

    private func icon(for variant: MVToastVariant) -> String {
        switch variant {
        case .info: return "info.circle"
        case .success: return "checkmark.circle"
        case .warning: return "exclamationmark.triangle"
        case .error: return "xmark.octagon"
        }
    }

    private func color(for variant: MVToastVariant) -> Color {
        switch variant {
        case .info: return .blue
        case .success: return .green
        case .warning: return .orange
        case .error: return MVPalette.destructive
        }
    }
}
