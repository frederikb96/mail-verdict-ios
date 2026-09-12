import MailVerdictKit
import SwiftUI
import UIKit
import UniformTypeIdentifiers

enum ComposerAttachSource {
    case photos, files
}

/// The composer body: a stock `UITextView` on TextKit 2. Formatting lives in semantic attributes
/// the package reads and writes (`ComposeFormatting`, `ComposeAttributedCodec`); this view only
/// forwards edits to them and draws the result through `ComposeStyler`. It grows with its text and
/// lets the sheet's scroll view do the scrolling, as Mail's composer does.
struct RichTextEditorView: UIViewRepresentable {
    let store: ComposerStore
    @Binding var height: CGFloat
    let onAttach: (ComposerAttachSource) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(store: store, height: $height, onAttach: onAttach)
    }

    func makeUIView(context: Context) -> ComposeTextView {
        let textView = ComposeTextView(usingTextLayoutManager: true)
        textView.isScrollEnabled = false
        textView.backgroundColor = .clear
        textView.font = UIFont.preferredFont(forTextStyle: .body)
        textView.adjustsFontForContentSizeCategory = true
        textView.textContainerInset = UIEdgeInsets(top: 10, left: 16, bottom: 16, right: 16)
        textView.textContainer.lineFragmentPadding = 0
        textView.allowsEditingTextAttributes = false
        textView.accessibilityLabel = "Message body"
        textView.accessibilityIdentifier = "composer-body"
        textView.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        // List markers are drawn by the layout, never stored as text, so the document read back
        // out of the storage holds only what was typed.
        (textView.textLayoutManager?.textContentManager as? NSTextContentStorage)?.includesTextListMarkers = false
        context.coordinator.attach(textView)
        return textView
    }

    func updateUIView(_ textView: ComposeTextView, context: Context) {
        context.coordinator.onAttach = onAttach
        context.coordinator.reloadIfNeeded()
    }

    @MainActor
    final class Coordinator: NSObject, UITextViewDelegate, UIGestureRecognizerDelegate {
        let store: ComposerStore
        var height: Binding<CGFloat>
        var onAttach: (ComposerAttachSource) -> Void

        private weak var textView: ComposeTextView?
        private var loadedRevision = -1
        private var pendingBreak: Int?
        private var pendingMerge: (location: Int, kind: ComposeBlockKind)?
        private var lastEdit: NSRange?
        private var images: [String: UIImage] = [:]
        private var formatPanel: ComposeFormatPanel?
        private var formatItem: UIBarButtonItem?
        private lazy var styler = ComposeStyler(image: { [weak self] contentId in self?.image(for: contentId) })

        init(store: ComposerStore, height: Binding<CGFloat>, onAttach: @escaping (ComposerAttachSource) -> Void) {
            self.store = store
            self.height = height
            self.onAttach = onAttach
        }

        func attach(_ textView: ComposeTextView) {
            self.textView = textView
            textView.delegate = self
            textView.onLayout = { [weak self] in self?.updateHeight() }
            textView.onPasteImages = { [weak self] images in self?.insertImages(images) }
            textView.onPasteHTML = { [weak self] html in self?.insertHTML(html) }
            textView.inputAccessoryView = makeAccessoryBar()

            let tap = UITapGestureRecognizer(target: self, action: #selector(handleTap(_:)))
            tap.delegate = self
            textView.addGestureRecognizer(tap)
            reloadIfNeeded()
        }

        /// Replaces the text whenever the store replaced the document (load, restore) — and only
        /// then, so the store echoing the editor's own edits back never resets the caret.
        func reloadIfNeeded() {
            guard let textView, store.documentRevision != loadedRevision else { return }
            loadedRevision = store.documentRevision
            images.removeAll()
            let text = ComposeAttributedCodec.attributedString(from: store.document)
            styler.style(text, range: NSRange(location: 0, length: text.length))
            textView.attributedText = text
            let lastBlock = store.document.blocks.last?.kind ?? .paragraph
            textView.typingAttributes = styler.typingAttributes(
                ComposeAttributedCodec.attributes(marks: [], link: nil, block: lastBlock))
            updateHeight()
        }

        // MARK: - Editing

        func textView(_ textView: UITextView, shouldChangeTextIn range: NSRange, replacementText text: String) -> Bool {
            guard textView.markedTextRange == nil else { return true }
            let storage = textView.textStorage
            var typing = semanticTyping()
            if text == "\n" {
                if ComposeFormatting.handleReturn(in: storage, selection: range, typing: &typing) {
                    finishFormatting(covering: range, typing: typing)
                    return false
                }
                pendingBreak = range.location
            } else if text.isEmpty, range.length == 1, range.location < storage.length {
                if ComposeFormatting.handleBackspace(deleting: range, in: storage, typing: &typing) {
                    finishFormatting(covering: NSRange(location: range.location + 1, length: 0), typing: typing)
                    return false
                }
                // Backspace joining two paragraphs keeps the kind of the one above, the paragraph
                // the caret is moving into.
                if NSString(string: storage.string).character(at: range.location) == 0x0A,
                    let kind = ComposeAttributedCodec.blockKind(at: range.location, in: storage)
                {
                    pendingMerge = (range.location, kind)
                }
            }
            lastEdit = NSRange(location: range.location, length: NSString(string: text).length)
            return true
        }

        func textViewDidChange(_ textView: UITextView) {
            // Mid-composition (dictation, a CJK input method) the marked text must not be restyled
            // under the input method; the edit that ends the composition arrives here again.
            guard textView.markedTextRange == nil else { return }
            let storage = textView.textStorage
            var typing = semanticTyping()
            var affected = lastEdit ?? textView.selectedRange
            storage.beginEditing()
            if let location = pendingBreak, location < storage.length {
                ComposeFormatting.didInsertParagraphBreak(at: location, in: storage, typing: &typing)
                affected = NSUnionRange(affected, NSRange(location: location, length: 1))
            }
            if let merge = pendingMerge {
                ComposeFormatting.setBlock(merge.kind, forParagraphAt: merge.location, in: storage, typing: &typing)
            }
            let clamped = clamp(affected, to: storage.length)
            ComposeFormatting.normalizeBlocks(in: storage, range: clamped, typing: typing)
            styler.style(storage, range: clamped)
            storage.endEditing()
            pendingBreak = nil
            pendingMerge = nil
            lastEdit = nil
            textView.typingAttributes = styler.typingAttributes(typing)
            report()
        }

        func textViewDidChangeSelection(_ textView: UITextView) {
            formatPanel?.update(currentFormatState())
            revealCaret()
        }

        func apply(_ item: ComposeFormatItem) {
            guard let textView else { return }
            let storage = textView.textStorage
            var typing = semanticTyping()
            let selection = textView.selectedRange
            storage.beginEditing()
            item.apply(to: storage, selection: selection, typing: &typing)
            storage.endEditing()
            finishFormatting(covering: selection, typing: typing)
            textView.selectedRange = selection
        }

        private func finishFormatting(covering range: NSRange, typing: ComposeFormatting.Attributes) {
            guard let textView else { return }
            let storage = textView.textStorage
            storage.beginEditing()
            styler.style(storage, range: clamp(range, to: storage.length))
            storage.endEditing()
            textView.typingAttributes = styler.typingAttributes(typing)
            report()
        }

        private func report() {
            guard let textView else { return }
            store.editorDidChange(
                ComposeAttributedCodec.document(
                    from: textView.textStorage, trailingBlock: ComposeAttributedCodec.block(in: semanticTyping())))
            formatPanel?.update(currentFormatState())
            updateHeight()
        }

        private func semanticTyping() -> ComposeFormatting.Attributes {
            guard let textView else { return [:] }
            let keys = Set(ComposeAttributedCodec.semanticKeys)
            return textView.typingAttributes.filter { keys.contains($0.key) }
        }

        private func currentFormatState() -> ComposeFormatState {
            guard let textView else { return ComposeFormatState() }
            return ComposeFormatting.formatState(
                in: textView.textStorage, selection: textView.selectedRange, typing: semanticTyping())
        }

        private func clamp(_ range: NSRange, to length: Int) -> NSRange {
            let location = min(max(range.location, 0), length)
            return NSRange(location: location, length: min(max(range.length, 0), length - location))
        }

        // MARK: - Pasting

        /// Parsed into the document model — structure and marks kept, markdown never read.
        private func insertHTML(_ html: String) {
            let parsed = ComposeHTMLParser.parse(html)
            store.registerInlineImages(parsed.images)
            insert(ComposeAttributedCodec.attributedString(from: parsed.document))
        }

        private func insertImages(_ pasted: [ComposePastedImage]) {
            var attributes = semanticTyping()
            let fragment = NSMutableAttributedString(string: "")
            for image in pasted {
                let reference = store.addInlineImage(
                    data: image.data, filename: image.filename, contentType: image.mimeType)
                attributes[.mvImage] = reference.contentId
                fragment.append(NSAttributedString(string: "\u{FFFC}", attributes: attributes))
            }
            insert(fragment)
        }

        private func insert(_ fragment: NSAttributedString) {
            guard let textView, fragment.length > 0 else { return }
            let storage = textView.textStorage
            let range = textView.selectedRange
            let piece = NSMutableAttributedString(attributedString: fragment)
            // A fragment of one paragraph joins the paragraph it lands in rather than bringing a
            // kind of its own — pasting a word into a list item leaves it a list item.
            if !piece.string.contains("\n") {
                let target = ComposeFormatting.paragraph(containing: range.location, in: storage)
                let kind = ComposeFormatting.blockKind(ofParagraph: target, in: storage, typing: semanticTyping())
                piece.addAttribute(
                    .mvBlock, value: kind.attributeValue, range: NSRange(location: 0, length: piece.length))
            }
            storage.beginEditing()
            storage.replaceCharacters(in: range, with: piece)
            let inserted = NSRange(location: range.location, length: piece.length)
            ComposeFormatting.normalizeBlocks(in: storage, range: inserted, typing: semanticTyping())
            styler.style(storage, range: inserted)
            storage.endEditing()
            textView.selectedRange = NSRange(location: NSMaxRange(inserted), length: 0)
            report()
        }

        private func image(for contentId: String) -> UIImage? {
            if let cached = images[contentId] { return cached }
            guard let data = store.inlineImages[contentId]?.data, let decoded = UIImage(data: data) else { return nil }
            images[contentId] = decoded
            return decoded
        }

        // MARK: - Links

        private func editLink() {
            guard let textView, let presenter = textView.window?.rootViewController?.topmostPresented else { return }
            let selection = textView.selectedRange
            let current =
                ComposeFormatting.linkRange(at: selection.location, in: textView.textStorage).flatMap {
                    textView.textStorage.attribute(.mvLink, at: $0.location, effectiveRange: nil) as? String
                } ?? ""
            let alert = UIAlertController(title: "Link", message: nil, preferredStyle: .alert)
            alert.addTextField { field in
                field.text = current
                field.placeholder = "https://"
                field.keyboardType = .URL
                field.autocapitalizationType = .none
                field.autocorrectionType = .no
                field.clearButtonMode = .whileEditing
            }
            alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
            alert.addAction(
                UIAlertAction(title: "OK", style: .default) { [weak self, weak alert] _ in
                    self?.setLink(alert?.textFields?.first?.text ?? "", selection: selection)
                })
            presenter.present(alert, animated: true)
        }

        /// An empty URL removes the link — the web's prompt, natively. A bare host gains https.
        private func setLink(_ raw: String, selection: NSRange) {
            guard let textView else { return }
            var url = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if !url.isEmpty, !url.contains("://"), !url.lowercased().hasPrefix("mailto:") { url = "https://" + url }
            let storage = textView.textStorage
            var typing = semanticTyping()
            storage.beginEditing()
            let next = ComposeFormatting.setLink(url, in: storage, selection: selection, typing: &typing)
            ComposeFormatting.normalizeBlocks(in: storage, range: NSUnionRange(selection, next), typing: typing)
            storage.endEditing()
            finishFormatting(covering: NSUnionRange(selection, next), typing: typing)
            textView.selectedRange = next
        }

        // MARK: - Checklist and image taps

        private enum TapTarget {
            case checkbox(Int)
            case image(NSRange)
        }

        func gestureRecognizer(
            _ gestureRecognizer: UIGestureRecognizer,
            shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
        ) -> Bool {
            true
        }

        func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
            guard let textView else { return false }
            return tapTarget(at: gestureRecognizer.location(in: textView)) != nil
        }

        @objc private func handleTap(_ recognizer: UITapGestureRecognizer) {
            guard let textView, let target = tapTarget(at: recognizer.location(in: textView)) else { return }
            switch target {
            case .checkbox(let location):
                let storage = textView.textStorage
                var typing = semanticTyping()
                storage.beginEditing()
                ComposeFormatting.toggleChecked(at: location, in: storage, typing: &typing)
                storage.endEditing()
                finishFormatting(covering: NSRange(location: location, length: 0), typing: typing)
            case .image(let range):
                presentImageMenu(for: range)
            }
        }

        /// A tap on an inline image, or in the marker column left of a checklist item's text.
        private func tapTarget(at point: CGPoint) -> TapTarget? {
            guard let textView, textView.textStorage.length > 0, let position = textView.closestPosition(to: point)
            else { return nil }
            let storage = textView.textStorage
            let index = textView.offset(from: textView.beginningOfDocument, to: position)

            for candidate in [index, index - 1] where candidate >= 0 && candidate < storage.length {
                guard storage.attribute(.mvImage, at: candidate, effectiveRange: nil) != nil,
                    let start = textView.position(from: textView.beginningOfDocument, offset: candidate),
                    let end = textView.position(from: start, offset: 1),
                    let textRange = textView.textRange(from: start, to: end)
                else { continue }
                if textView.firstRect(for: textRange).insetBy(dx: -4, dy: -4).contains(point) {
                    return .image(NSRange(location: candidate, length: 1))
                }
            }

            let paragraph = ComposeFormatting.paragraph(containing: min(index, storage.length), in: storage)
            guard paragraph.length > 0,
                case .listItem(.checklist, _, _) = ComposeAttributedCodec.blockKind(
                    at: NSMaxRange(paragraph) - 1, in: storage)
            else { return nil }
            let style =
                storage.attribute(.paragraphStyle, at: paragraph.location, effectiveRange: nil) as? NSParagraphStyle
            let indent = style?.headIndent ?? ComposeStyler.listIndent
            return point.x - textView.textContainerInset.left < indent ? .checkbox(paragraph.location) : nil
        }

        /// The web's corner-drag resize, as the four sizes a touch can pick reliably.
        private func presentImageMenu(for range: NSRange) {
            guard let textView, let presenter = textView.window?.rootViewController?.topmostPresented else { return }
            let sheet = UIAlertController(title: nil, message: nil, preferredStyle: .actionSheet)
            let sizes: [(String, String?)] = [
                ("Small", "160"), ("Medium", "320"), ("Large", "480"), ("Full Width", "100%"),
            ]
            for (title, width) in sizes {
                sheet.addAction(
                    UIAlertAction(title: title, style: .default) { [weak self] _ in
                        self?.setImageWidth(width, range: range)
                    })
            }
            sheet.addAction(
                UIAlertAction(title: "Remove", style: .destructive) { [weak self] _ in self?.removeImage(at: range) })
            sheet.addAction(UIAlertAction(title: "Cancel", style: .cancel))
            if let popover = sheet.popoverPresentationController {
                popover.sourceView = textView
                popover.sourceRect = textView.bounds
            }
            presenter.present(sheet, animated: true)
        }

        private func setImageWidth(_ width: String?, range: NSRange) {
            guard let textView, NSMaxRange(range) <= textView.textStorage.length else { return }
            let storage = textView.textStorage
            storage.beginEditing()
            if let width {
                storage.addAttribute(.mvImageWidth, value: width, range: range)
            } else {
                storage.removeAttribute(.mvImageWidth, range: range)
            }
            storage.endEditing()
            finishFormatting(covering: range, typing: semanticTyping())
        }

        /// Through the text view's own editing path, so it can be undone like any deletion.
        private func removeImage(at range: NSRange) {
            guard let textView, NSMaxRange(range) <= textView.textStorage.length,
                let start = textView.position(from: textView.beginningOfDocument, offset: range.location),
                let end = textView.position(from: start, offset: range.length),
                let textRange = textView.textRange(from: start, to: end)
            else { return }
            textView.replace(textRange, withText: "")
        }

        // MARK: - Keyboard accessory

        private func makeAccessoryBar() -> UIToolbar {
            let bar = UIToolbar(frame: CGRect(x: 0, y: 0, width: 0, height: 44))
            let format = UIBarButtonItem(
                image: UIImage(systemName: MVSymbols.format), style: .plain, target: self,
                action: #selector(toggleFormatPanel))
            format.accessibilityLabel = "Format"
            formatItem = format

            let attach = UIBarButtonItem(
                image: UIImage(systemName: MVSymbols.attach),
                menu: UIMenu(children: [
                    UIAction(title: "Photo Library", image: UIImage(systemName: "photo.on.rectangle")) {
                        [weak self] _ in
                        self?.onAttach(.photos)
                    },
                    UIAction(title: "Choose File", image: UIImage(systemName: "folder")) { [weak self] _ in
                        self?.onAttach(.files)
                    },
                ]))
            attach.accessibilityLabel = "Attach"

            let link = UIBarButtonItem(
                image: UIImage(systemName: MVSymbols.link), style: .plain, target: self, action: #selector(linkTapped))
            link.accessibilityLabel = "Link"

            let dismiss = UIBarButtonItem(
                image: UIImage(systemName: "keyboard.chevron.compact.down"), style: .plain, target: self,
                action: #selector(dismissKeyboard))
            dismiss.accessibilityLabel = "Hide Keyboard"

            bar.items = [format, attach, link, UIBarButtonItem(systemItem: .flexibleSpace), dismiss]
            bar.sizeToFit()
            return bar
        }

        /// Aa swaps the keyboard for the format panel and back.
        @objc private func toggleFormatPanel() {
            guard let textView else { return }
            if textView.inputView == nil {
                let panel = formatPanel ?? ComposeFormatPanel { [weak self] item in self?.apply(item) }
                formatPanel = panel
                panel.update(currentFormatState())
                textView.inputView = panel
                formatItem?.image = UIImage(systemName: "keyboard")
            } else {
                textView.inputView = nil
                formatItem?.image = UIImage(systemName: MVSymbols.format)
            }
            if textView.isFirstResponder {
                textView.reloadInputViews()
            } else {
                textView.becomeFirstResponder()
            }
        }

        @objc private func linkTapped() {
            editLink()
        }

        @objc private func dismissKeyboard() {
            textView?.resignFirstResponder()
        }

        // MARK: - Size and caret

        func updateHeight() {
            guard let textView, textView.bounds.width > 0 else { return }
            let fitted = textView.sizeThatFits(CGSize(width: textView.bounds.width, height: .greatestFiniteMagnitude))
                .height
            guard abs(fitted - height.wrappedValue) > 0.5 else { return }
            // Deferred: this runs inside a layout pass, where SwiftUI state must not change.
            Task { @MainActor [weak self] in
                self?.height.wrappedValue = fitted
                self?.revealCaret()
            }
        }

        /// The text view does not scroll itself, so the sheet's scroll view is asked to keep the
        /// caret in view.
        private func revealCaret() {
            guard let textView, textView.isFirstResponder, let selection = textView.selectedTextRange else { return }
            var ancestor = textView.superview
            while let view = ancestor, !(view is UIScrollView) { ancestor = view.superview }
            guard let scrollView = ancestor as? UIScrollView else { return }
            let caret = textView.caretRect(for: selection.end)
            guard !caret.isNull, !caret.isInfinite else { return }
            scrollView.scrollRectToVisible(
                textView.convert(caret, to: scrollView).insetBy(dx: 0, dy: -28), animated: false)
        }
    }
}

/// A `UITextView` that pastes rich content as the composer understands it: HTML (from Safari,
/// Notes, Mail and most apps, or wrapped in a web archive) goes through the document parser, and
/// an image becomes an inline image rather than a refused paste.
final class ComposeTextView: UITextView {
    var onLayout: (() -> Void)?
    var onPasteImages: (([ComposePastedImage]) -> Void)?
    var onPasteHTML: ((String) -> Void)?

    private static let htmlTypes = [UTType.html.identifier, "com.apple.webarchive"]
    /// Preference order: the first type an item carries wins, so a screenshot offering PNG and
    /// JPEG is taken losslessly.
    private static let imageTypes: [UTType] = [.png, .jpeg, .heic, .gif, .webP, .tiff]

    override func layoutSubviews() {
        super.layoutSubviews()
        onLayout?()
    }

    /// Type checks only — reading pasteboard contents here would raise the paste banner every
    /// time the edit menu appears.
    override func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool {
        if action == #selector(paste(_:)),
            UIPasteboard.general.hasImages || UIPasteboard.general.contains(pasteboardTypes: Self.htmlTypes)
        {
            return true
        }
        return super.canPerformAction(action, withSender: sender)
    }

    override func paste(_ sender: Any?) {
        let pasteboard = UIPasteboard.general
        if let html = Self.html(from: pasteboard) {
            onPasteHTML?(html)
            return
        }
        let images = Self.images(from: pasteboard)
        if !images.isEmpty {
            onPasteImages?(images)
            return
        }
        super.paste(sender)
    }

    private static func html(from pasteboard: UIPasteboard) -> String? {
        if let data = pasteboard.data(forPasteboardType: UTType.html.identifier),
            let html = String(data: data, encoding: .utf8)
        {
            return html
        }
        if let html = pasteboard.value(forPasteboardType: UTType.html.identifier) as? String { return html }
        if let archive = pasteboard.data(forPasteboardType: "com.apple.webarchive"),
            let plist = try? PropertyListSerialization.propertyList(from: archive, format: nil) as? [String: Any],
            let main = plist["WebMainResource"] as? [String: Any],
            let bytes = main["WebResourceData"] as? Data
        {
            return String(data: bytes, encoding: .utf8)
        }
        return nil
    }

    /// The copied bytes themselves where a known type carries them; a decoded `UIImage` only as
    /// the fallback, since re-encoding would send bytes that are not the ones copied.
    private static func images(from pasteboard: UIPasteboard) -> [ComposePastedImage] {
        var result: [ComposePastedImage] = []
        for (index, item) in pasteboard.items.enumerated() {
            if let typed = imageTypes.lazy.compactMap({ type -> ComposePastedImage? in
                guard let data = item[type.identifier] as? Data else { return nil }
                return ComposePastedImage(
                    data: data, filename: "pasted-image-\(index + 1).\(type.preferredFilenameExtension ?? "img")",
                    mimeType: type.preferredMIMEType ?? "application/octet-stream")
            }).first {
                result.append(typed)
            } else if let image = item.values.compactMap({ $0 as? UIImage }).first, let data = image.pngData() {
                result.append(
                    ComposePastedImage(data: data, filename: "pasted-image-\(index + 1).png", mimeType: "image/png"))
            }
        }
        return result
    }
}

struct ComposePastedImage {
    let data: Data
    let filename: String
    let mimeType: String
}

extension UIViewController {
    /// The controller an alert has to be presented from — whatever is already presented on top.
    var topmostPresented: UIViewController {
        var top = self
        while let presented = top.presentedViewController { top = presented }
        return top
    }
}
