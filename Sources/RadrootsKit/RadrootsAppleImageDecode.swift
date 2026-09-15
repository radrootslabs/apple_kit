import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Admission bounds for one actor-owned decode. The working-byte estimate
/// includes compressed input, an eight-bit source raster, and three derivative
/// rasters (thumbnail, color conversion and encoder input). ImageIO owns its
/// internal codec workspace; this is not a process RSS or allocator guarantee.
enum RadrootsAppleImageDecode {
    static let maximumSourceDimension = 32768
    static let maximumRasterBytes = 160_000_000
    static let maximumWorkingBytes = 512 * 1024 * 1024

    static func validateDimensions(
        width: Int, height: Int, inputBytes: Int, maximumPixelCount: Int, maximumDimension: Int
    ) throws {
        guard (1 ... maximumSourceDimension).contains(width),
              (1 ... maximumSourceDimension).contains(height),
              (0 ... (40 * 1024 * 1024)).contains(inputBytes),
              (1 ... 8192).contains(maximumDimension)
        else { throw RadrootsAppleMediaPreparationError.invalidRequest }
        // Dimension admission precedes all multiplication; these products fit
        // Int on every supported 64-bit Apple target.
        let pixels = width * height
        let sourceBytes = pixels * 4
        let derivativePixels = min(pixels, maximumDimension * maximumDimension)
        guard pixels <= maximumPixelCount, sourceBytes <= maximumRasterBytes,
              inputBytes + sourceBytes + derivativePixels * 4 * 3 <= maximumWorkingBytes
        else { throw RadrootsAppleMediaPreparationError.invalidRequest }
    }

    static func normalizedImage(_ data: Data, request: RadrootsAppleImagePreparationRequest) throws -> CGImage {
        try Task.checkCancellation()
        guard !data.isEmpty, data.count <= request.maximumInputBytes,
              let source = CGImageSourceCreateWithData(
                  data as CFData,
                  [kCGImageSourceShouldCache: false] as CFDictionary
              ),
              let type = CGImageSourceGetType(source) as String?,
              [UTType.jpeg.identifier, UTType.png.identifier, UTType.heic.identifier, UTType.heif.identifier]
              .contains(type),
              CGImageSourceGetCount(source) == 1,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let widthNumber = properties[kCGImagePropertyPixelWidth] as? NSNumber,
              let heightNumber = properties[kCGImagePropertyPixelHeight] as? NSNumber,
              let width = Int(exactly: widthNumber.doubleValue),
              let height = Int(exactly: heightNumber.doubleValue),
              let depth = (properties[kCGImagePropertyDepth] as? NSNumber)?.intValue,
              (1 ... 8).contains(depth)
        else { throw RadrootsAppleMediaPreparationError.invalidRequest }
        try validateDimensions(width: width, height: height, inputBytes: data.count,
                               maximumPixelCount: request.maximumPixelCount, maximumDimension: request.maximumDimension)
        try Task.checkCancellation()
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceShouldAllowFloat: false,
            kCGImageSourceThumbnailMaxPixelSize: request.maximumDimension
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary),
              image.width > 0, image.height > 0,
              image.width <= request.maximumDimension, image.height <= request.maximumDimension,
              image.width * image.height <= request.maximumPixelCount,
              (1 ... 8).contains(image.bitsPerComponent), image.bitsPerPixel <= 32,
              image.bytesPerRow > 0, image.bytesPerRow <= maximumRasterBytes / image.height
        else { throw RadrootsAppleMediaPreparationError.invalidRequest }
        try Task.checkCancellation()
        // Render pixels into a standard space so source ICC/device profiles and
        // image properties cannot ride along with the sanitized derivative.
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: image.width, height: image.height,
                                      bitsPerComponent: 8, bytesPerRow: image.width * 4, space: space,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { throw RadrootsAppleMediaPreparationError.preparationFailure }
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        try Task.checkCancellation()
        guard let normalized = context.makeImage() else {
            throw RadrootsAppleMediaPreparationError.preparationFailure
        }
        return normalized
    }
}
