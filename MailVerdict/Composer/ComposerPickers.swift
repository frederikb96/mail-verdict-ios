import MailVerdictKit
import PhotosUI
import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// The system photo picker: it runs out of process, so it needs no photo-library permission, and
/// hands back compatible formats (JPEG rather than HEIC) the way Mail attaches photos.
struct ComposerPhotoPicker: UIViewControllerRepresentable {
    /// Called the moment the picker is done, before its files are read — the sheet closes at once.
    let onFinish: @MainActor () -> Void
    let onPick: @MainActor ([ComposeAttachment]) -> Void

    func makeUIViewController(context: Context) -> PHPickerViewController {
        var configuration = PHPickerConfiguration()
        configuration.selectionLimit = 0
        configuration.preferredAssetRepresentationMode = .compatible
        let picker = PHPickerViewController(configuration: configuration)
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ picker: PHPickerViewController, context: Context) {
        context.coordinator.onFinish = onFinish
        context.coordinator.onPick = onPick
    }

    func makeCoordinator() -> Coordinator { Coordinator(onFinish: onFinish, onPick: onPick) }

    @MainActor
    final class Coordinator: NSObject {
        var onFinish: @MainActor () -> Void
        var onPick: @MainActor ([ComposeAttachment]) -> Void

        init(onFinish: @escaping @MainActor () -> Void, onPick: @escaping @MainActor ([ComposeAttachment]) -> Void) {
            self.onFinish = onFinish
            self.onPick = onPick
        }
    }
}

extension ComposerPhotoPicker.Coordinator: @preconcurrency PHPickerViewControllerDelegate {
    func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
        onFinish()
        guard !results.isEmpty else { return }
        ComposerItemLoader.load(results.map(\.itemProvider)) { [weak self] attachments in
            Task { @MainActor in self?.onPick(attachments) }
        }
    }
}

/// Reads each picked item's file representation. The picker hands out temporary files that are
/// deleted once the callback returns, so the bytes are read inside it.
enum ComposerItemLoader {
    static func load(_ providers: [NSItemProvider], completion: @escaping @Sendable ([ComposeAttachment]) -> Void) {
        let collector = Collector(count: providers.count)
        let group = DispatchGroup()
        for (index, provider) in providers.enumerated() {
            let types = provider.registeredContentTypes
            guard let type = types.first(where: { $0.conforms(to: .image) || $0.conforms(to: .movie) }) ?? types.first
            else { continue }
            let baseName = provider.suggestedName ?? "Attachment \(index + 1)"
            let filename = type.preferredFilenameExtension.map { baseName + "." + $0 } ?? baseName
            let mimeType = type.preferredMIMEType
            group.enter()
            _ = provider.loadFileRepresentation(for: type, openInPlace: false) { url, _, _ in
                if let url, let data = try? Data(contentsOf: url) {
                    collector.set(ComposeAttachment(filename: filename, contentType: mimeType, data: data), at: index)
                }
                group.leave()
            }
        }
        group.notify(queue: .main) { completion(collector.values) }
    }

    /// Callbacks arrive on arbitrary queues; a lock keeps the results in picking order.
    private final class Collector: @unchecked Sendable {
        private let lock = NSLock()
        private var slots: [ComposeAttachment?]

        init(count: Int) {
            slots = Array(repeating: nil, count: count)
        }

        func set(_ attachment: ComposeAttachment, at index: Int) {
            lock.lock()
            slots[index] = attachment
            lock.unlock()
        }

        var values: [ComposeAttachment] {
            lock.lock()
            defer { lock.unlock() }
            return slots.compactMap { $0 }
        }
    }
}

/// Files picked through `.fileImporter`, read inside their security scope — the scope does not
/// outlive the pick, so the bytes are copied into the composer straight away.
enum ComposerFileReader {
    static func read(_ urls: [URL]) async -> [ComposeAttachment] {
        urls.compactMap { url -> ComposeAttachment? in
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            guard let data = try? Data(contentsOf: url) else { return nil }
            return ComposeAttachment(
                filename: url.lastPathComponent,
                contentType: UTType(filenameExtension: url.pathExtension)?.preferredMIMEType, data: data)
        }
    }
}
