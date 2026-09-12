import MailVerdictKit
import SwiftUI
import UIKit

/// One recipient row: the label, a chip per address, and a text field that turns what is typed
/// into chips on Return, a comma or semicolon, a paste containing either, or leaving the field.
/// Text that is not an address stays in the field in red with a note saying so.
struct RecipientTokenField: View {
    let field: ComposeRecipientField
    let store: ComposerStore
    @Binding var activeField: ComposeRecipientField?
    let onQueryChange: (String) -> Void

    @State private var selected: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text("\(field.label):")
                    .foregroundStyle(.secondary)
                RecipientFlowLayout {
                    ForEach(store.recipients(field), id: \.self) { address in
                        token(address)
                    }
                    RecipientTextField(
                        text: store.recipientText[field] ?? "",
                        isInvalid: store.recipientNotes[field] != nil,
                        label: field.label,
                        onChange: { text in
                            selected = nil
                            store.updateRecipientText(text, for: field)
                            onQueryChange(store.recipientText[field] ?? "")
                        },
                        onReturn: {
                            store.commitRecipientText(field)
                            onQueryChange("")
                        },
                        onBackspaceWhenEmpty: backspace,
                        onFocusChange: { focused in
                            if focused {
                                activeField = field
                            } else {
                                store.commitRecipientText(field)
                                if activeField == field { activeField = nil }
                                selected = nil
                            }
                        })
                }
            }
            if let note = store.recipientNotes[field] {
                Text(note)
                    .font(.footnote)
                    .foregroundStyle(MVPalette.destructive)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .accessibilityIdentifier("composer-\(field.rawValue)")
    }

    private func token(_ address: String) -> some View {
        let isSelected = selected == address
        return Text(address)
            .font(.subheadline)
            .lineLimit(1)
            .truncationMode(.middle)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .foregroundStyle(isSelected ? Color.white : Color.accentColor)
            .background(Capsule().fill(isSelected ? Color.accentColor : Color.accentColor.opacity(0.12)))
            .contentShape(Capsule())
            .onTapGesture { selected = isSelected ? nil : address }
            .contextMenu {
                Button("Copy", systemImage: "doc.on.doc") { UIPasteboard.general.string = address }
                Button("Remove", systemImage: "minus.circle", role: .destructive) {
                    store.removeRecipient(address, from: field)
                }
            }
            .accessibilityLabel(address)
            .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    /// The first Backspace in an empty field selects the last chip, the second removes it — the
    /// Mail token field's own rhythm.
    private func backspace() {
        if let chosen = selected {
            store.removeRecipient(chosen, from: field)
            selected = nil
        } else {
            selected = store.recipients(field).last
        }
    }
}

/// Chips laid out left to right, wrapping as needed; the last subview — the text field — takes
/// the rest of its line, or a line of its own when too little is left.
struct RecipientFlowLayout: Layout {
    var spacing: CGFloat = 6
    var lineSpacing: CGFloat = 6
    var trailingMinimumWidth: CGFloat = 96

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        arrange(width: proposal.width ?? 320, subviews: subviews).size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let arrangement = arrange(width: bounds.width, subviews: subviews)
        for (index, frame) in arrangement.frames.enumerated() {
            subviews[index].place(
                at: CGPoint(x: bounds.minX + frame.minX, y: bounds.minY + frame.minY),
                proposal: ProposedViewSize(frame.size))
        }
    }

    private func arrange(width: CGFloat, subviews: Subviews) -> (frames: [CGRect], size: CGSize) {
        var frames: [CGRect] = []
        var x: CGFloat = 0
        var y: CGFloat = 0
        var lineHeight: CGFloat = 0
        for (index, subview) in subviews.enumerated() {
            var size = subview.sizeThatFits(.unspecified)
            if index == subviews.count - 1 {
                if x > 0, width - x < trailingMinimumWidth {
                    x = 0
                    y += lineHeight + lineSpacing
                    lineHeight = 0
                }
                size.width = max(width - x, 1)
                size.height = subview.sizeThatFits(ProposedViewSize(width: size.width, height: nil)).height
            } else {
                size.width = min(size.width, width)
                if x > 0, x + size.width > width {
                    x = 0
                    y += lineHeight + lineSpacing
                    lineHeight = 0
                }
            }
            frames.append(CGRect(origin: CGPoint(x: x, y: y), size: size))
            x += size.width + spacing
            lineHeight = max(lineHeight, size.height)
        }
        return (frames, CGSize(width: width, height: y + lineHeight))
    }
}

/// A `UITextField`, because a SwiftUI one cannot report Backspace in an empty field — the key
/// that selects and removes chips.
private struct RecipientTextField: UIViewRepresentable {
    let text: String
    let isInvalid: Bool
    let label: String
    let onChange: (String) -> Void
    let onReturn: () -> Void
    let onBackspaceWhenEmpty: () -> Void
    let onFocusChange: (Bool) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    func makeUIView(context: Context) -> BackspaceTextField {
        let textField = BackspaceTextField()
        textField.keyboardType = .emailAddress
        textField.textContentType = .emailAddress
        textField.autocapitalizationType = .none
        textField.autocorrectionType = .no
        textField.spellCheckingType = .no
        textField.returnKeyType = .next
        textField.font = UIFont.preferredFont(forTextStyle: .body)
        textField.adjustsFontForContentSizeCategory = true
        textField.accessibilityLabel = label
        textField.delegate = context.coordinator
        textField.addTarget(
            context.coordinator, action: #selector(Coordinator.editingChanged(_:)), for: .editingChanged)
        textField.setContentHuggingPriority(.defaultLow, for: .horizontal)
        textField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return textField
    }

    func updateUIView(_ textField: BackspaceTextField, context: Context) {
        context.coordinator.parent = self
        if textField.text != text { textField.text = text }
        textField.textColor = isInvalid ? .systemRed : .label
        textField.onBackspaceWhenEmpty = { [coordinator = context.coordinator] in
            coordinator.parent.onBackspaceWhenEmpty()
        }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: BackspaceTextField, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? 96, height: max(uiView.intrinsicContentSize.height, 30))
    }

    @MainActor
    final class Coordinator: NSObject, UITextFieldDelegate {
        var parent: RecipientTextField

        init(parent: RecipientTextField) {
            self.parent = parent
        }

        @objc func editingChanged(_ textField: UITextField) {
            parent.onChange(textField.text ?? "")
        }

        func textFieldShouldReturn(_ textField: UITextField) -> Bool {
            parent.onReturn()
            return false
        }

        func textFieldDidBeginEditing(_ textField: UITextField) {
            parent.onFocusChange(true)
        }

        func textFieldDidEndEditing(_ textField: UITextField) {
            parent.onFocusChange(false)
        }
    }
}

final class BackspaceTextField: UITextField {
    var onBackspaceWhenEmpty: (() -> Void)?

    override func deleteBackward() {
        if text?.isEmpty ?? true { onBackspaceWhenEmpty?() }
        super.deleteBackward()
    }
}
