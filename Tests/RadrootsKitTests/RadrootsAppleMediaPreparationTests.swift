import CoreGraphics
import Foundation
import ImageIO
@testable import RadrootsKit
import Testing
import UniformTypeIdentifiers

@Test func appleMediaPreparationNormalizesAndCommitsStableFinalBytes() async throws {
    let roots = try mediaPreparationRoots()
    let sourceReference = RadrootsFileReference(scope: .cache, relativePath: "capture/source.jpg")
    let sourceURL = try roots.resolvedURL(for: sourceReference)
    try writeOrientedImageWithMetadata(to: sourceURL)
    let preparer = RadrootsAppleMediaPreparer(roots: roots)
    let request = try RadrootsAppleImagePreparationRequest(source: .file(sourceReference))

    let first = try await preparer.prepareImage(request)
    let second = try await preparer.prepareImage(request)

    #expect(first == second)
    #expect(first.width == 3)
    #expect(first.height == 2)
    #expect(first.file.mediaType == "image/png")
    #expect(first.file.sizeBytes > 0)
    #expect(first.sha256.count == 64)
    #expect(!first.debugDescription.contains(roots.temporaryRoot.path))
    let outputURL = try roots.stagedBlobURL(for: first.file)
    let outputSource = try #require(CGImageSourceCreateWithURL(outputURL as CFURL, nil))
    let outputProperties = try #require(CGImageSourceCopyPropertiesAtIndex(outputSource, 0, nil) as? [CFString: Any])
    #expect(outputProperties[kCGImagePropertyGPSDictionary] == nil)
    #expect((outputProperties[kCGImagePropertyOrientation] as? NSNumber)?.intValue ?? 1 == 1)
}

@Test func appleMediaPreparationBuildsBoundedBlossomUploadRequest() async throws {
    let roots = try mediaPreparationRoots()
    let sourceReference = RadrootsFileReference(scope: .cache, relativePath: "capture/source.jpg")
    try writeOrientedImageWithMetadata(to: roots.resolvedURL(for: sourceReference))
    let preparer = RadrootsAppleMediaPreparer(roots: roots)
    let prepared = try await preparer.prepareImage(RadrootsAppleImagePreparationRequest(source: .file(sourceReference)))

    let request = try await preparer.blossomUploadRequest(
        preparedImage: prepared, remoteURL: #require(URL(string: "https://blossom.radroots.org/upload")), authorization: "Nostr signed-event",
        identifier: RadrootsBackgroundTransferIdentifier("field.media.upload")
    )

    #expect(request.method == .put)
    #expect(request.operation == .upload(source: .stagedBlob(prepared.file)))
    #expect(request.headers["Authorization"] == "Nostr signed-event")
    #expect(request.headers["Content-Type"] == "image/png")
    #expect(request.metadata["sha256"] == prepared.sha256)
    #expect(try request.responsePolicy == .boundedJSON())
    #expect(request.expectedSourceSHA256 == prepared.sha256)

    let preparedURL = try roots.stagedBlobURL(for: prepared.file)
    var tampered = try Data(contentsOf: preparedURL)
    tampered[tampered.startIndex] ^= 0x01
    try tampered.write(to: preparedURL, options: .atomic)
    await #expect(throws: RadrootsAppleMediaPreparationError.invalidRequest("prepared image no longer matches its commitment")) {
        _ = try await preparer.blossomUploadRequest(
            preparedImage: prepared, remoteURL: #require(URL(string: "https://blossom.radroots.org/upload")), authorization: "Nostr signed-event"
        )
    }
}

@Test func appleMediaPreparationEnforcesByteAndProtectedDataBounds() async throws {
    let roots = try mediaPreparationRoots()
    let sourceReference = RadrootsFileReference(scope: .cache, relativePath: "capture/source.jpg")
    try writeOrientedImageWithMetadata(to: roots.resolvedURL(for: sourceReference))

    let bounded = RadrootsAppleMediaPreparer(roots: roots)
    await #expect(throws: RadrootsAppleMediaPreparationError.invalidRequest("image source is unavailable or exceeds its byte limit")) {
        _ = try await bounded.prepareImage(RadrootsAppleImagePreparationRequest(source: .file(sourceReference), maximumInputBytes: 1))
    }

    let locked = RadrootsAppleMediaPreparer(roots: roots, protectedData: RadrootsProtectedDataProvider { .locked })
    await #expect(throws: RadrootsAppleMediaPreparationError.unavailable("image preparation protected data is unavailable")) {
        _ = try await locked.prepareImage(RadrootsAppleImagePreparationRequest(source: .file(sourceReference)))
    }
}

private func writeOrientedImageWithMetadata(to url: URL) throws {
    let colorSpace = CGColorSpaceCreateDeviceRGB()
    let context = try #require(
        CGContext(
            data: nil, width: 2, height: 3, bitsPerComponent: 8, bytesPerRow: 8, space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )
    )
    context.setFillColor(CGColor(red: 0.2, green: 0.7, blue: 0.3, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: 2, height: 3))
    let image = try #require(context.makeImage())
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    let destination = try #require(CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil))
    let properties: [CFString: Any] = [
        kCGImagePropertyOrientation: 6, kCGImagePropertyGPSDictionary: [kCGImagePropertyGPSLatitude: 45.0],
        kCGImageDestinationLossyCompressionQuality: 0.9,
    ]
    CGImageDestinationAddImage(destination, image, properties as CFDictionary)
    try #require(CGImageDestinationFinalize(destination))
}

private func mediaPreparationRoots() throws -> RadrootsAppleFileRoots {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
        "radroots-media-preparation-\(UUID().uuidString)", isDirectory: true
    )
    return try RadrootsAppleFileRoots(
        appIdentifier: "org.radroots.tests", dataRoot: root.appendingPathComponent("data", isDirectory: true),
        cacheRoot: root.appendingPathComponent("cache", isDirectory: true),
        temporaryRoot: root.appendingPathComponent("tmp", isDirectory: true)
    )
}
