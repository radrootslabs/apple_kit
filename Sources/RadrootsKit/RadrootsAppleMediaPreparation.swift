import CryptoKit
import Foundation
import ImageIO
import UniformTypeIdentifiers

public enum RadrootsAppleMediaPreparationError: Error, Equatable, Sendable {
    case invalidRequest(String)
    case unavailable(String)
    case preparationFailure(String)
}

extension RadrootsAppleMediaPreparationError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case let .invalidRequest(message), let .unavailable(message), let .preparationFailure(message): message
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
        guard (1 ... (40 * 1024 * 1024)).contains(maximumInputBytes), (1 ... (10 * 1024 * 1024)).contains(maximumOutputBytes),
              (1 ... 40_000_000).contains(maximumPixelCount), (1 ... 8192).contains(maximumDimension)
        else { throw RadrootsAppleMediaPreparationError.invalidRequest("image preparation limits are invalid") }
        do { try RadrootsBackgroundTransferValidation.validateLocalFile(source) } catch {
            throw RadrootsAppleMediaPreparationError.invalidRequest("image source handle is invalid")
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

    public init(file: RadrootsStagedBlobReference, sha256: String, width: UInt32, height: UInt32) throws {
        guard sha256.range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil, width > 0, height > 0, file.sizeBytes > 0,
              file.mediaType == "image/png"
        else { throw RadrootsAppleMediaPreparationError.invalidRequest("prepared image commitment is invalid") }
        self.file = file
        self.sha256 = sha256
        self.width = width
        self.height = height
    }

    public var debugDescription: String {
        "RadrootsApplePreparedImage(sha256: \(sha256), sizeBytes: \(file.sizeBytes), width: \(width), height: \(height))"
    }
}

public actor RadrootsAppleMediaPreparer {
    private let roots: RadrootsAppleFileRoots
    private let resolver: RadrootsAppleBackgroundTransferFileResolver
    private let fileManager: FileManager
    private let protectedData: RadrootsProtectedDataProvider

    public init(
        roots: RadrootsAppleFileRoots, fileManager: FileManager = .default, protectedData: RadrootsProtectedDataProvider = .available
    ) {
        self.roots = roots
        resolver = RadrootsAppleBackgroundTransferFileResolver(roots: roots)
        self.fileManager = fileManager
        self.protectedData = protectedData
    }

    public func prepareImage(_ request: RadrootsAppleImagePreparationRequest) async throws -> RadrootsApplePreparedImage {
        do { return try await prepareValidatedImage(request) } catch is CancellationError { throw CancellationError() } catch let error
            as RadrootsAppleMediaPreparationError
        { throw error } catch { throw RadrootsAppleMediaPreparationError.preparationFailure("image preparation failed") }
    }

    private func prepareValidatedImage(_ request: RadrootsAppleImagePreparationRequest) async throws -> RadrootsApplePreparedImage {
        try Task.checkCancellation()
        try requireProtectedData()
        let sourceURL = try resolver.resolve(request.source)
        let sourceValues = try sourceURL.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey, .isSymbolicLinkKey])
        guard sourceValues.isRegularFile == true, sourceValues.isSymbolicLink != true, let inputBytes = sourceValues.fileSize,
              inputBytes > 0, inputBytes <= request.maximumInputBytes
        else { throw RadrootsAppleMediaPreparationError.invalidRequest("image source is unavailable or exceeds its byte limit") }
        guard let source = CGImageSourceCreateWithURL(sourceURL as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
              CGImageSourceGetCount(source) == 1
        else { throw RadrootsAppleMediaPreparationError.invalidRequest("image source must contain exactly one decodable image") }
        let dimensions = try Self.sourceDimensions(source)
        guard dimensions.pixelCount <= request.maximumPixelCount else {
            throw RadrootsAppleMediaPreparationError.invalidRequest("image source exceeds its pixel limit")
        }
        let thumbnailOptions: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true, kCGImageSourceThumbnailMaxPixelSize: request.maximumDimension,
        ]
        guard let normalizedImage = CGImageSourceCreateThumbnailAtIndex(source, 0, thumbnailOptions as CFDictionary) else {
            throw RadrootsAppleMediaPreparationError.preparationFailure("image normalization failed")
        }
        try Task.checkCancellation()

        let temporaryURL = roots.temporaryRoot.appendingPathComponent("media_preparation", isDirectory: true).appendingPathComponent(
            "\(UUID().uuidString.lowercased()).png"
        ).standardizedFileURL
        defer {
            if fileManager.fileExists(atPath: temporaryURL.path) {
                try? fileManager.removeItem(at: temporaryURL)
            }
        }
        try fileManager.createDirectory(at: temporaryURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        #if os(iOS)
            try fileManager.setAttributes(
                [.protectionKey: FileProtectionType.complete], ofItemAtPath: temporaryURL.deletingLastPathComponent().path
            )
        #endif
        guard let destination = CGImageDestinationCreateWithURL(temporaryURL as CFURL, UTType.png.identifier as CFString, 1, nil) else {
            throw RadrootsAppleMediaPreparationError.preparationFailure("image destination could not be created")
        }
        CGImageDestinationAddImage(destination, normalizedImage, [:] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else {
            throw RadrootsAppleMediaPreparationError.preparationFailure("image encoding failed")
        }
        try Task.checkCancellation()
        let outputSize = try Self.fileSize(at: temporaryURL)
        guard outputSize > 0, outputSize <= request.maximumOutputBytes else {
            throw RadrootsAppleMediaPreparationError.invalidRequest("normalized image exceeds its byte limit")
        }
        let digest = try RadrootsAppleFileDigest.sha256(at: temporaryURL)
        let staged = try RadrootsStagedBlobReference(
            blobID: digest, sizeBytes: outputSize, mediaType: "image/png", filenameHint: "\(digest).png"
        )
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
                [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: stagedURL.path
            )
        #endif
        return try RadrootsApplePreparedImage(
            file: staged, sha256: digest, width: UInt32(normalizedImage.width), height: UInt32(normalizedImage.height)
        )
    }

    public func blossomUploadRequest(
        preparedImage: RadrootsApplePreparedImage, remoteURL: URL, authorization: String,
        networkPolicy: RadrootsBackgroundTransferNetworkPolicy = .publicHTTPS,
        identifier: RadrootsBackgroundTransferIdentifier = .generated()
    ) throws -> RadrootsBackgroundTransferRequest {
        do {
            let fileURL = try roots.stagedBlobURL(for: preparedImage.file)
            guard try Self.fileSize(at: fileURL) == preparedImage.file.sizeBytes,
                  try RadrootsAppleFileDigest.sha256(at: fileURL) == preparedImage.sha256
            else { throw RadrootsAppleMediaPreparationError.invalidRequest("prepared image no longer matches its commitment") }
            return try RadrootsBackgroundTransferRequest(
                identifier: identifier, remoteURL: remoteURL, method: .put, operation: .upload(source: .stagedBlob(preparedImage.file)),
                headers: ["Authorization": authorization, "Content-Type": "image/png"],
                metadata: ["purpose": "blossom_upload", "sha256": preparedImage.sha256], networkPolicy: networkPolicy,
                responsePolicy: .boundedJSON(), expectedSourceSHA256: preparedImage.sha256
            )
        } catch let error as RadrootsAppleMediaPreparationError { throw error } catch let error as RadrootsBackgroundTransferError {
            throw error
        } catch { throw RadrootsAppleMediaPreparationError.preparationFailure("prepared image commitment could not be verified") }
    }

    private func requireProtectedData() throws {
        guard protectedData.currentState() == .available else {
            throw RadrootsAppleMediaPreparationError.unavailable("image preparation protected data is unavailable")
        }
    }

    private static func sourceDimensions(_ source: CGImageSource) throws -> (width: Int, height: Int, pixelCount: Int) {
        guard let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue,
              let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue, width > 0, height > 0, width <= Int.max / height
        else { throw RadrootsAppleMediaPreparationError.invalidRequest("image dimensions are invalid") }
        return (width, height, width * height)
    }

    private static func fileSize(at url: URL) throws -> Int {
        guard let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize else {
            throw RadrootsAppleMediaPreparationError.preparationFailure("prepared image size is unavailable")
        }
        return size
    }
}

enum RadrootsAppleFileDigest {
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
