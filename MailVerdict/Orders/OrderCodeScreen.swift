import MailVerdictKit
import SwiftUI
import UIKit

/// One code, as large as the screen allows, on white, at full brightness: what a person holds up to
/// a gate scanner. The brightness they had comes back when the code goes away -- by closing it,
/// by the app leaving the foreground, or by anything else that removes the view.
struct OrderCodeScreen: View {
    let store: OrderDetailStore
    let fact: OrderFactOut
    let onClose: () -> Void

    @Environment(\.scenePhase) private var scenePhase
    @State private var image: UIImage?
    @State private var didFail = false
    @State private var brightness = ScreenBrightnessHold()

    var body: some View {
        ZStack {
            Color.white.ignoresSafeArea()
            VStack(spacing: 16) {
                VStack(spacing: 4) {
                    Text(fact.displayLabel)
                        .font(.title3.weight(.semibold))
                    if let merchant = store.order?.merchant {
                        Text(merchant).font(.subheadline).foregroundStyle(.secondary)
                    }
                }
                .padding(.top, 8)
                codeView
                if let payload = fact.code?.payloadText, !payload.isEmpty {
                    Text(payload).font(.title3.monospaced()).textSelection(.enabled)
                } else if !fact.value.isEmpty {
                    Text(fact.value).font(.title3.monospaced()).textSelection(.enabled)
                }
                Spacer(minLength: 0)
            }
            .padding(16)
            .foregroundStyle(Color.black)
        }
        .overlay(alignment: .topTrailing) {
            Button(action: onClose) {
                Image(systemName: "xmark.circle.fill")
                    .font(.title)
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(Color.black)
                    .padding(16)
            }
            .accessibilityLabel("Close code")
            .accessibilityIdentifier("order-code-close")
        }
        .environment(\.colorScheme, .light)
        .accessibilityIdentifier("order-code-screen")
        .task(id: fact.id) {
            image = nil
            didFail = false
            if let data = await store.codeImage(for: fact), let decoded = UIImage(data: data) {
                image = decoded
            } else {
                didFail = true
            }
        }
        .onAppear { brightness.engage() }
        .onDisappear { brightness.release() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { brightness.engage() } else { brightness.release() }
        }
        #if DEBUG
            .onChange(of: image != nil, initial: true) { _, loaded in
                OrdersDebugState.shared.codeShown = loaded
            }
            .onDisappear { OrdersDebugState.shared.codeShown = false }
        #endif
    }

    @ViewBuilder
    private var codeView: some View {
        GeometryReader { proxy in
            let side = max(min(proxy.size.width, proxy.size.height), 0)
            Group {
                if let image {
                    Image(uiImage: image)
                        .resizable()
                        .interpolation(.none)
                        .scaledToFit()
                        .accessibilityLabel("\(fact.displayLabel) code")
                } else if didFail {
                    VStack(spacing: 8) {
                        Image(systemName: "qrcode").font(.largeTitle)
                        Text("The code could not be loaded.").font(.subheadline)
                    }
                } else {
                    ProgressView()
                }
            }
            .frame(width: side, height: side)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

/// Raises the screen to full brightness and keeps the display awake, remembering what to put back.
/// `MVBrightnessHold` decides when to save and restore; this applies it to the screen.
@MainActor
struct ScreenBrightnessHold {
    private var hold = MVBrightnessHold()
    private var idleTimerWasDisabled = false

    private static var screen: UIScreen? {
        UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first?.screen
    }

    mutating func engage() {
        guard let screen = Self.screen else { return }
        if let target = hold.engage(current: Double(screen.brightness)) {
            screen.brightness = CGFloat(target)
            idleTimerWasDisabled = UIApplication.shared.isIdleTimerDisabled
            UIApplication.shared.isIdleTimerDisabled = true
        }
    }

    mutating func release() {
        guard let restore = hold.release() else { return }
        Self.screen?.brightness = CGFloat(restore)
        UIApplication.shared.isIdleTimerDisabled = idleTimerWasDisabled
    }
}
