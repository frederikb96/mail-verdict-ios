import MailVerdictKit
import SwiftUI
import UIKit

/// The facts someone looks up later, most important first: scannable codes as thumbnails that
/// open fullscreen, then each fact with its label. A tracking number opens the carrier's page and
/// a link opens in the browser; anything else copies on tap. Every fact copies from its menu.
struct OrderFactsSection: View {
    let store: OrderDetailStore
    let order: OrderDetail
    let environment: AppEnvironment

    @Environment(\.openURL) private var openURL

    var body: some View {
        Section("Key facts") {
            if !order.codeFacts.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 12) {
                        ForEach(order.codeFacts) { fact in
                            CodeThumbnail(store: store, fact: fact)
                        }
                    }
                    .padding(.vertical, 4)
                }
                .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
            }
            ForEach(order.detailFacts) { fact in
                row(for: fact)
            }
        }
    }

    @ViewBuilder
    private func row(for fact: OrderFactOut) -> some View {
        let link = fact.linkURL
        Button {
            if let link {
                openURL(link)
            } else {
                copy(fact)
            }
        } label: {
            LabeledContent(fact.displayLabel) {
                HStack(spacing: 6) {
                    Text(fact.value)
                        .font(fact.kind.isIdentifier ? .body.monospaced() : .body)
                        .foregroundStyle(.primary)
                        .multilineTextAlignment(.trailing)
                    if link != nil {
                        Image(systemName: "arrow.up.right.square").foregroundStyle(.secondary)
                    }
                }
            }
        }
        .contextMenu {
            Button {
                copy(fact)
            } label: {
                Label("Copy", systemImage: "doc.on.doc")
            }
            if let link {
                Button {
                    openURL(link)
                } label: {
                    Label(fact.kind == .trackingNumber ? "Track Shipment" : "Open Link", systemImage: "safari")
                }
            }
        }
        .accessibilityLabel(
            "\(fact.displayLabel) \(fact.value)\(link == nil ? ", double tap to copy" : ", double tap to open")")
    }

    private func copy(_ fact: OrderFactOut) {
        guard let text = fact.copyText else { return }
        UIPasteboard.general.string = text
        environment.toasts.show(.init(variant: .info, message: "Copied", duration: 2))
    }
}

extension OrderFactKind {
    /// Numbers a person reads out or types: set in a monospaced face.
    fileprivate var isIdentifier: Bool {
        switch self {
        case .orderNumber, .bookingCode, .ticketNumber, .invoiceNumber, .trackingNumber: return true
        default: return false
        }
    }
}

/// A code drawn small, white as a scanner wants it; a tap opens it fullscreen.
private struct CodeThumbnail: View {
    let store: OrderDetailStore
    let fact: OrderFactOut

    @State private var image: UIImage?
    @State private var didFail = false

    var body: some View {
        Button {
            store.presentCode(fact)
        } label: {
            VStack(spacing: 6) {
                ZStack {
                    RoundedRectangle(cornerRadius: 10).fill(Color.white)
                    if let image {
                        Image(uiImage: image)
                            .resizable()
                            .interpolation(.none)
                            .scaledToFit()
                            .padding(8)
                    } else if didFail {
                        Image(systemName: "qrcode").foregroundStyle(.gray)
                    } else {
                        ProgressView()
                    }
                }
                .frame(width: 112, height: 112)
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.secondary.opacity(0.3)))
                Text(fact.displayLabel)
                    .font(.caption)
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .frame(width: 112)
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(fact.displayLabel) code, double tap to show fullscreen")
        .accessibilityIdentifier("order-code-thumbnail")
        .task(id: fact.id) {
            if let data = await store.codeImage(for: fact), let decoded = UIImage(data: data) {
                image = decoded
            } else {
                didFail = true
            }
        }
    }
}
