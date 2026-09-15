import CryptoKit
import Foundation
import ImageIO
import UniformTypeIdentifiers

public enum RadrootsAppleMediaPreparationError: Error, Equatable, Sendable {
    case invalidRequest
    case unavailable
    case preparationFailure
}

extension RadrootsAppleMediaPreparationError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .invalidRequest: "The media preparation request is invalid."
        case .unavailable: "Media preparation is unavailable."
        case .preparationFailure: "The media could not be prepared."
        }
    }
}

public struct RadrootsAppleImagePreparationRequest: Sendable, Equatable, Hashable {
    public let source: RadrootsBackgroundTransferLocalFile
    public let maximumInputBytes: Int
    public let maximumOutputBytes: Int
    public let maximumPixelCount: Int
    public let maximumDimension: Int

    public init(
        source: RadrootsBackgroundTransferLocalFile, maximumInputBytes: Int = 40 * 1024 * 1024,
        maximumOutputBytes: Int = 10 * 1024 * 1024, maximumPixelCount: Int = 40_000_000, maximumDimension: Int = 4096
    ) throws {
        guard (1 ... (40 * 1024 * 1024)).contains(maximumInputBytes),
              (1 ... (10 * 1024 * 1024)).contains(maximumOutputBytes),
              (1 ... 40_000_000).contains(maximumPixelCount), (1 ... 8192).contains(maximumDimension)
        else { throw RadrootsAppleMediaPreparationError.invalidRequest }
        do { try RadrootsBackgroundTransferValidation.validateLocalFile(source) } catch {
            throw RadrootsAppleMediaPreparationError.invalidRequest
        }
        self.source = source
        self.maximumInputBytes = maximumInputBytes
        self.maximumOutputBytes = maximumOutputBytes
        self.maximumPixelCount = maximumPixelCount
        self.maximumDimension = maximumDimension
    }
}

public struct RadrootsApplePreparedImage: Sendable, Equatable, Hashable, CustomDebugStringConvertible {
    public let file: RadrootsStagedBlobReference
    public let sha256: String
    public let width: UInt32
    public let height: UInt32

    public init(
        file: RadrootsStagedBlobReference, sha256: String, width: UInt32, height: UInt32
    ) throws {
        guard sha256.range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil, width > 0,
              height > 0, file.sizeBytes > 0,
              file.mediaType == "image/png"
        else { throw RadrootsAppleMediaPreparationError.invalidRequest }
        self.file = file
        self.sha256 = sha256
        self.width = width
        self.height = height
    }

    public var debugDescription: String {
        "RadrootsApplePreparedImage(sha256: \(sha256), sizeBytes: \(file.sizeBytes), "
            + "width: \(width), height: \(height))"
    }
}

public actor RadrootsAppleMediaPreparer {
    private let roots: RadrootsAppleFileRoots
    private let resolver: RadrootsAppleBackgroundTransferFileResolver
    private let fileManager: FileManager
    private let protectedData: RadrootsProtectedDataProvider

    public init(
        roots: RadrootsAppleFileRoots, fileManager: FileManager = .default,
        protectedData: RadrootsProtectedDataProvider = .available
    ) {
        self.roots = roots
        resolver = RadrootsAppleBackgroundTransferFileResolver(roots: roots)
        self.fileManager = fileManager
        self.protectedData = protectedData
    }

    /// Prepares a single-frame JPEG, PNG or HEIF/HEIC raster with at most
    /// eight-bit source components. Source axes are limited to 32,768 pixels;
    /// the existing request limits and a 512 MiB raster working-byte estimate
    /// apply before decoding. One request decodes at a time per preparer.
    /// The returned PNG contains oriented standard-sRGB pixels, without source
    /// location, device, comment or camera-profile metadata.
    public func prepareImage(
        _ request: RadrootsAppleImagePreparationRequest
    ) async throws -> RadrootsApplePreparedImage {
        // One actor-owned, non-suspending decode at a time. Drain native temporary
        // objects before another queued request can allocate its raster buffers.
        do { return try autoreleasepool { try prepareValidatedImage(request) } } catch is CancellationError {
            throw CancellationError()
        } catch let error as RadrootsAppleMediaPreparationError {
            throw error
        } catch { throw RadrootsAppleMediaPreparationError.preparationFailure }
    }

    private func prepareValidatedImage(
        _ request: RadrootsAppleImagePreparationRequest
    ) throws -> RadrootsApplePreparedImage {
        try Task.checkCancellation()
        try requireProtectedData()
        let sourceData = try readSource(request)
        let normalizedImage = try RadrootsAppleImageDecode.normalizedImage(sourceData, request: request)
        try Task.checkCancellation()

        let temporaryURL = roots.temporaryRoot.appendingPathComponent(
            "media_preparation", isDirectory: true
        ).appendingPathComponent(
            "\(UUID().uuidString.lowercased()).png"
        ).standardizedFileURL
        defer {
            if fileManager.fileExists(atPath: temporaryURL.path) {
                try? fileManager.removeItem(at: temporaryURL)
            }
        }
        try encodePNG(normalizedImage, at: temporaryURL)
        try Task.checkCancellation()
        let outputSize = try Self.fileSize(at: temporaryURL)
        guard outputSize > 0, outputSize <= request.maximumOutputBytes else {
            throw RadrootsAppleMediaPreparationError.invalidRequest
        }
        let digest = try RadrootsAppleFileDigest.sha256(at: temporaryURL)
        let staged = try RadrootsStagedBlobReference(
            blobID: digest, sizeBytes: outputSize, mediaType: "image/png", filenameHint: "\(digest).png"
        )
        try Task.checkCancellation()
        try requireProtectedData()
        try Task.checkCancellation()
        let stagedURL = try roots.stagedBlobURL(for: staged)
        try fileManager.createDirectory(at: roots.stagedBlobsRoot, withIntermediateDirectories: true)
        if fileManager.fileExists(atPath: stagedURL.path) {
            let existingSize = try Self.fileSize(at: stagedURL)
            let existingDigest = try RadrootsAppleFileDigest.sha256(at: stagedURL)
            if existingSize != outputSize || existingDigest != digest {
                try fileManager.removeItem(at: stagedURL)
                try fileManager.moveItem(at: temporaryURL, to: stagedURL)
            }
        } else {
            try fileManager.moveItem(at: temporaryURL, to: stagedURL)
        }
        #if os(iOS)
            try fileManager.setAttributes(
                [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
                ofItemAtPath: stagedURL.path
            )
        #endif
        return try RadrootsApplePreparedImage(
            file: staged, sha256: digest, width: UInt32(normalizedImage.width),
            height: UInt32(normalizedImage.height)
        )
    }

    public func blossomUploadRequest(
        preparedImage: RadrootsApplePreparedImage, remoteURL: URL, authorization: String,
        networkPolicy: RadrootsBackgroundTransferNetworkPolicy = .publicHTTPS,
        identifier: RadrootsBackgroundTransferIdentifier = .generated()
    ) throws -> RadrootsBackgroundTransferRequest {
        do {
            let preparedData = try resolver.read(
                .stagedBlob(preparedImage.file), maximumBytes: preparedImage.file.sizeBytes
            )
            guard preparedData.count == preparedImage.file.sizeBytes,
                  RadrootsAppleFileDigest.sha256(preparedData) == preparedImage.sha256
            else { throw RadrootsAppleMediaPreparationError.invalidRequest }
            return try RadrootsBackgroundTransferRequest(
                identifier: identifier, remoteURL: remoteURL, method: .put,
                operation: .upload(source: .stagedBlob(preparedImage.file)),
                headers: [
                    "Authorization": authorization, "Content-Type": "image/png",
                    "X-SHA-256": preparedImage.sha256,
                    "Accept": "application/json", "Accept-Encoding": "identity"
                ],
                metadata: ["purpose": "blossom_upload", "sha256": preparedImage.sha256],
                networkPolicy: networkPolicy,
                responsePolicy: .boundedJSON(), expectedSourceSHA256: preparedImage.sha256
            )
        } catch let error as RadrootsAppleMediaPreparationError { throw error
        } catch let error as RadrootsBackgroundTransferError {
            throw error
        } catch { throw RadrootsAppleMediaPreparationError.preparationFailure }
    }

    private func readSource(_ request: RadrootsAppleImagePreparationRequest) throws -> Data {
        do {
            return try resolver.read(request.source, maximumBytes: request.maximumInputBytes)
        } catch {
            throw RadrootsAppleMediaPreparationError.invalidRequest
        }
    }

    private func encodePNG(_ image: CGImage, at url: URL) throws {
        try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        #if os(iOS)
            try fileManager.setAttributes(
                [.protectionKey: FileProtectionType.complete],
                ofItemAtPath: url.deletingLastPathComponent().path
            )
        #endif
        guard let destination = CGImageDestinationCreateWithURL(
            url as CFURL, UTType.png.identifier as CFString, 1, nil
        ) else {
            throw RadrootsAppleMediaPreparationError.preparationFailure
        }
        CGImageDestinationAddImage(destination, image, [:] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else {
            throw RadrootsAppleMediaPreparationError.preparationFailure
        }
    }

    private func requireProtectedData() throws {
        guard protectedData.currentState() == .available else {
            throw RadrootsAppleMediaPreparationError.unavailable
        }
    }

    private static func fileSize(at url: URL) throws -> Int {
        guard let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize else {
            throw RadrootsAppleMediaPreparationError.preparationFailure
        }
        return size
    }
}

enum RadrootsAppleFileDigest {
    static func sha256(_ data: Data) -> String {
        CryptoKit.SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    static func sha256(at url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = CryptoKit.SHA256()
        while true {
            let chunk = try handle.read(upToCount: 64 * 1024) ?? Data()
            if chunk.isEmpty {
                break
            }
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
