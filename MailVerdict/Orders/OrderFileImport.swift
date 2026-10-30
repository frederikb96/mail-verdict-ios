import MailVerdictKit
import PhotosUI
import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// A file or photo the person picked, ready to send: the server takes JPEG where the Photos
/// library hands out HEIC, so images are converted here.
struct PickedOrderFile: Sendable {
    let filename: String
    let contentType: String
    let data: Data
}

enum OrderFilePicking {
    /// Reads a file from the Files picker. The URL is security scoped for the length of the read.
    static func read(url: URL) throws -> PickedOrderFile {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let data = try Data(contentsOf: url)
        let type = UTType(filenameExtension: url.pathExtension)?.preferredMIMEType
        return normalized(filename: url.lastPathComponent, contentType: type, data: data)
    }

    static func normalized(filename: String, contentType: String?, data: Data) -> PickedOrderFile {
        if OrderUploadFile.needsJPEGConversion(contentType: contentType, filename: filename),
            let image = UIImage(data: data), let jpeg = image.jpegData(compressionQuality: 0.9)
        {
            return PickedOrderFile(
                filename: OrderUploadFile.jpegFilename(for: filename), contentType: "image/jpeg", data: jpeg)
        }
        return PickedOrderFile(
            filename: filename.isEmpty ? "document" : filename,
            contentType: contentType ?? "application/octet-stream", data: data)
    }
}

struct OrderFilePickingModifier: ViewModifier {
    @Binding var isImporting: Bool
    @Binding var isPickingPhoto: Bool
    let onPicked: (PickedOrderFile) -> Void
    let onFailure: (Error) -> Void

    @State private var photos: [PhotosPickerItem] = []

    init(
        isImporting: Binding<Bool>, isPickingPhoto: Binding<Bool>, onPicked: @escaping (PickedOrderFile) -> Void,
        onFailure: @escaping (Error) -> Void
    ) {
        self._isImporting = isImporting
        self._isPickingPhoto = isPickingPhoto
        self.onPicked = onPicked
        self.onFailure = onFailure
    }

    func body(content: Content) -> some View {
        content
            .fileImporter(isPresented: $isImporting, allowedContentTypes: [.item], allowsMultipleSelection: true) {
                result in
                switch result {
                case .success(let urls):
                    for url in urls {
                        do {
                            onPicked(try OrderFilePicking.read(url: url))
                        } catch {
                            onFailure(error)
                        }
                    }
                case .failure(let error):
                    onFailure(error)
                }
            }
            .photosPicker(isPresented: $isPickingPhoto, selection: $photos, maxSelectionCount: 10, matching: .images)
            .onChange(of: photos) { _, items in
                guard !items.isEmpty else { return }
                photos = []
                Task {
                    for (index, item) in items.enumerated() {
                        do {
                            guard let data = try await item.loadTransferable(type: Data.self) else { continue }
                            let type = item.supportedContentTypes.first
                            let ext = type?.preferredFilenameExtension ?? "jpg"
                            onPicked(
                                OrderFilePicking.normalized(
                                    filename: "photo-\(index + 1).\(ext)", contentType: type?.preferredMIMEType,
                                    data: data))
                        } catch {
                            onFailure(error)
                        }
                    }
                }
            }
    }
}

extension View {
    /// The Files picker and the photo picker behind two flags; each picked file arrives once, ready
    /// to upload.
    func orderFileImport(
        isImporting: Binding<Bool>, isPickingPhoto: Binding<Bool>, onPicked: @escaping (PickedOrderFile) -> Void,
        onFailure: @escaping (Error) -> Void
    ) -> some View {
        modifier(
            OrderFilePickingModifier(
                isImporting: isImporting, isPickingPhoto: isPickingPhoto, onPicked: onPicked, onFailure: onFailure))
    }
}
