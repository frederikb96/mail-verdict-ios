#if canImport(ImageIO) && canImport(UniformTypeIdentifiers)
    import Foundation
    import ImageIO
    import UniformTypeIdentifiers

    /// Applies ``ShareImagePlan``: re-encodes an image as JPEG, scaled down when the plan asks.
    ///
    /// Decoding goes through ImageIO at the target size. Decoding the whole photo first costs its
    /// full pixel count in memory, which is past what an app extension may hold, and the system
    /// ends one that goes over without a word.
    public enum ShareImageFit {

        public static func apply(_ file: ShareFile, policy: ShareFitPolicy) -> ShareFile {
            let options = [kCGImageSourceShouldCache: false] as CFDictionary
            guard let source = CGImageSourceCreateWithData(file.data as CFData, options),
                let longestEdge = longestEdge(of: source),
                let plan = ShareImagePlan.plan(
                    contentType: file.contentType, filename: file.filename, longestEdge: longestEdge,
                    policy: policy),
                let jpeg = jpegData(from: source, maxPixels: min(longestEdge, plan.maxLongEdge ?? longestEdge))
            else { return file }
            return ShareFile(
                filename: OrderUploadFile.jpegFilename(for: file.filename), contentType: "image/jpeg", data: jpeg)
        }

        private static func longestEdge(of source: CGImageSource) -> Double? {
            guard let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
                let width = properties[kCGImagePropertyPixelWidth] as? Double,
                let height = properties[kCGImagePropertyPixelHeight] as? Double
            else { return nil }
            return max(width, height)
        }

        private static func jpegData(from source: CGImageSource, maxPixels: Double) -> Data? {
            let thumbnailOptions =
                [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceCreateThumbnailWithTransform: true,
                    kCGImageSourceShouldCacheImmediately: true,
                    kCGImageSourceThumbnailMaxPixelSize: Int(maxPixels.rounded()),
                ] as CFDictionary
            guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, thumbnailOptions) else { return nil }
            let output = NSMutableData()
            guard let destination = CGImageDestinationCreateWithData(output, UTType.jpeg.identifier as CFString, 1, nil)
            else { return nil }
            CGImageDestinationAddImage(
                destination, image, [kCGImageDestinationLossyCompressionQuality: 0.85] as CFDictionary)
            guard CGImageDestinationFinalize(destination) else { return nil }
            return output as Data
        }
    }
#endif
