import CoreGraphics
import Darwin
import Foundation
import ImageIO
@testable import RadrootsKit

@Test func imageDecodeAcceptsSupportedCameraRastersAsSanitizedPNG() async throws {
    let fixture = try ImageDecodeFixture()
    defer { fixture.remove() }
    let preparer = RadrootsAppleMediaPreparer(roots: fixture.roots)
    for type in [UTType.jpeg, UTType.png, UTType.heic] {
        try fixture.writeImage(type: type, dimension: 64)
        let result = try await preparer.prepareImage(.init(source: fixture.source))
        #expect(result.width == 64 && result.height == 64)
        #expect(result.file.mediaType == "image/png")
        let bytes = try Data(contentsOf: fixture.roots.stagedBlobURL(for: result.file))
        #expect(RadrootsAppleFileDigest.sha256(bytes) == result.sha256)
        let source = try #require(CGImageSourceCreateWithData(bytes as CFData, nil))
        #expect(CGImageSourceGetType(source) as String? == UTType.png.identifier)
    }
}

import Testing
import UniformTypeIdentifiers

@Test func imageDecodeRejectsDimensionPixelAndWorkingMemoryBombsBeforeAllocation() throws {
    try RadrootsAppleImageDecode.validateDimensions(width: 8000, height: 5000, inputBytes: 40 * 1024 * 1024,
                                                    maximumPixelCount: 40_000_000, maximumDimension: 4096)
    #expect(throws: RadrootsAppleMediaPreparationError.invalidRequest) {
        try RadrootsAppleImageDecode.validateDimensions(width: 8000, height: 5000, inputBytes: 1,
                                                        maximumPixelCount: 39_999_999, maximumDimension: 4096)
    }
    for dimension in [0, -1, 32769, Int.max] {
        #expect(throws: RadrootsAppleMediaPreparationError.invalidRequest) {
            try RadrootsAppleImageDecode.validateDimensions(width: dimension, height: 1, inputBytes: 1,
                                                            maximumPixelCount: 40_000_000, maximumDimension: 4096)
        }
    }
    // 32,768,000 pixels and three same-sized derivative rasters consume
    // 524,288,000 bytes. This input reaches the 512 MiB admission boundary.
    try RadrootsAppleImageDecode.validateDimensions(width: 8192, height: 4000, inputBytes: 12_582_912,
                                                    maximumPixelCount: 40_000_000, maximumDimension: 8192)
    #expect(throws: RadrootsAppleMediaPreparationError.invalidRequest) {
        try RadrootsAppleImageDecode.validateDimensions(width: 8192, height: 4000, inputBytes: 12_582_913,
                                                        maximumPixelCount: 40_000_000, maximumDimension: 8192)
    }
}

@Test func imageDecodeEnforcesActualInputOutputAndPixelBoundaries() async throws {
    let fixture = try ImageDecodeFixture()
    defer { fixture.remove() }
    try fixture.writeImage()
    let size = try Data(contentsOf: fixture.sourceURL).count
    let preparer = RadrootsAppleMediaPreparer(roots: fixture.roots)
    let first = try await preparer.prepareImage(.init(
        source: fixture.source,
        maximumInputBytes: size,
        maximumPixelCount: 16
    ))
    let exact = try await preparer.prepareImage(.init(source: fixture.source, maximumOutputBytes: first.file.sizeBytes))
    #expect(exact == first)
    for request in try [
        RadrootsAppleImagePreparationRequest(source: fixture.source, maximumInputBytes: size - 1),
        RadrootsAppleImagePreparationRequest(source: fixture.source, maximumOutputBytes: first.file.sizeBytes - 1),
        RadrootsAppleImagePreparationRequest(source: fixture.source, maximumPixelCount: 15)
    ] {
        await #expect(throws: RadrootsAppleMediaPreparationError.invalidRequest) {
            _ = try await preparer.prepareImage(request)
        }
    }
    let tiny = try await preparer.prepareImage(.init(source: fixture.source, maximumDimension: 1))
    #expect(tiny.width == 1 && tiny.height == 1)
    let bytes = try Data(contentsOf: fixture.roots.stagedBlobURL(for: tiny.file))
    #expect(RadrootsAppleFileDigest.sha256(bytes) == tiny.sha256)
    let decoded = try #require(CGImageSourceCreateWithData(bytes as CFData, nil))
    let image = try #require(CGImageSourceCreateImageAtIndex(decoded, 0, nil))
    #expect(image.width == 1 && image.height == 1 && image.bitsPerComponent == 8)
    #expect(try fixture.temporaryFiles().isEmpty)
}

@Test func imageDecodeRejectsMalformedUnsupportedHighDepthAndMultipleFrames() async throws {
    let fixture = try ImageDecodeFixture()
    defer { fixture.remove() }
    let preparer = RadrootsAppleMediaPreparer(roots: fixture.roots)
    let request = try RadrootsAppleImagePreparationRequest(source: fixture.source)
    for bytes in [Data(), Data("not a raster".utf8), ImageDecodeFixture.hugePNGHeader()] {
        try bytes.write(to: fixture.sourceURL)
        await #expect(throws: RadrootsAppleMediaPreparationError.invalidRequest) {
            _ = try await preparer.prepareImage(request)
        }
    }
    for (type, depth, frames) in [(UTType.gif, 8, 1), (UTType.png, 16, 1), (UTType.png, 8, 2)] {
        try fixture.writeImage(type: type, depth: depth, frames: frames)
        let source = try #require(CGImageSourceCreateWithURL(fixture.sourceURL as CFURL, nil))
        if depth == 16 {
            let properties = try #require(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
            #expect((properties[kCGImagePropertyDepth] as? NSNumber)?.intValue == 16)
        }
        #expect(CGImageSourceGetCount(source) == frames)
        await #expect(throws: RadrootsAppleMediaPreparationError.invalidRequest) {
            _ = try await preparer.prepareImage(request)
        }
    }
    #expect(try fixture.temporaryFiles().isEmpty)
}

@Test func imageDecodeCancellationAndConcurrentRequestsLeaveOneSanitizedIdentity() async throws {
    let fixture = try ImageDecodeFixture()
    defer { fixture.remove() }
    try fixture.writeImage()
    let preparer = RadrootsAppleMediaPreparer(roots: fixture.roots)
    let request = try RadrootsAppleImagePreparationRequest(source: fixture.source)
    let cancelled = Task {
        withUnsafeCurrentTask { $0?.cancel() }
        return try await preparer.prepareImage(request)
    }
    await #expect(throws: CancellationError.self) { try await cancelled.value }
    #expect(!FileManager.default.fileExists(atPath: fixture.roots.stagedBlobsRoot.path))
    let results = try await withThrowingTaskGroup(of: RadrootsApplePreparedImage.self) { group in
        for _ in 0 ..< 8 {
            group.addTask { try await preparer.prepareImage(request) }
        }
        var values: [RadrootsApplePreparedImage] = []
        for try await value in group {
            values.append(value)
        }
        return values
    }
    #expect(results.count == 8)
    #expect(Set(results).count == 1)
    #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.roots.stagedBlobsRoot.path).count == 1)
    #expect(try fixture.temporaryFiles().isEmpty)
}

private struct ImageDecodeFixture {
    let base: URL
    let roots: RadrootsAppleFileRoots
    let sourceURL: URL
    let source: RadrootsBackgroundTransferLocalFile

    init() throws {
        let unresolved = FileManager.default.temporaryDirectory
            .appendingPathComponent("radroots-image-decode-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: unresolved, withIntermediateDirectories: true)
        let pointer = try #require(unresolved.path.withCString { Darwin.realpath($0, nil) })
        defer { Darwin.free(pointer) }
        base = URL(fileURLWithPath: String(cString: pointer), isDirectory: true)
        roots = try RadrootsAppleFileRoots(
            appIdentifier: "org.radroots.tests",
            dataRoot: base.appendingPathComponent("data"),
            cacheRoot: base.appendingPathComponent("cache"),
            temporaryRoot: base.appendingPathComponent("tmp")
        )
        let reference = RadrootsFileReference(scope: .cache, relativePath: "source.image")
        source = .file(reference)
        sourceURL = try roots.resolvedURL(for: reference)
        try FileManager.default.createDirectory(
            at: sourceURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
    }

    func remove() {
        try? FileManager.default.removeItem(at: base)
    }

    func temporaryFiles() throws -> [String] {
        let path = roots.temporaryRoot.appendingPathComponent("media_preparation").path
        return FileManager.default.fileExists(atPath: path) ? try FileManager.default
            .contentsOfDirectory(atPath: path) : []
    }

    func writeImage(type: UTType = .png, depth: Int = 8, frames: Int = 1, dimension: Int = 4) throws {
        let pixels = Data(repeating: 127, count: dimension * dimension * 4 * (depth / 8))
        let provider = try #require(CGDataProvider(data: pixels as CFData))
        let image = try #require(CGImage(
            width: dimension,
            height: dimension,
            bitsPerComponent: depth,
            bitsPerPixel: depth * 4,
            bytesPerRow: dimension * 4 * (depth / 8),
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue),
            provider: provider,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
        ))
        let destination = try #require(CGImageDestinationCreateWithURL(
            sourceURL as CFURL,
            type.identifier as CFString,
            frames,
            nil
        ))
        for _ in 0 ..< frames {
            CGImageDestinationAddImage(destination, image, nil)
        }
        try #require(CGImageDestinationFinalize(destination))
    }

    static func hugePNGHeader() -> Data {
        // A valid CRC over a claimed 2^31-1 square raster, without allocating
        // pixel storage. Decoders must reject it before raster allocation.
        var payload: [UInt8] = [73, 72, 68, 82, 127, 255, 255, 255, 127, 255, 255, 255, 8, 6, 0, 0, 0]
        var crc: UInt32 = 0xFFFF_FFFF
        for byte in payload {
            crc ^= UInt32(byte)
            for _ in 0 ..< 8 {
                crc = (crc >> 1) ^ (crc & 1 == 0 ? 0 : 0xEDB8_8320)
            }
        }
        crc ^= 0xFFFF_FFFF
        payload += [
            UInt8(truncatingIfNeeded: crc >> 24),
            UInt8(truncatingIfNeeded: crc >> 16),
            UInt8(truncatingIfNeeded: crc >> 8),
            UInt8(truncatingIfNeeded: crc)
        ]
        return Data([137, 80, 78, 71, 13, 10, 26, 10, 0, 0, 0, 13] + payload + [
            0,
            0,
            0,
            0,
            73,
            69,
            78,
            68,
            174,
            66,
            96,
            130
        ])
    }
}
