import Foundation

public enum RadrootsCaptureIntakeError: Error, Equatable, Sendable {
    case invalidRequest
    case unavailable
    case permissionDenied
    case userCancelled
    case transientFailure
    case permanentFailure
}

extension RadrootsCaptureIntakeError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .invalidRequest: "The capture request is invalid."
        case .unavailable: "Capture is unavailable."
        case .permissionDenied: "Capture permission was denied."
        case .userCancelled: "Capture was cancelled."
        case .transientFailure: "Capture could not be completed temporarily."
        case .permanentFailure: "Capture could not be completed."
        }
    }
}

public enum RadrootsMediaKind: String, Sendable, Equatable, Hashable, CaseIterable {
    case image
}

public enum RadrootsMediaSource: String, Sendable, Equatable, Hashable {
    case libraryImport
    case cameraCapture
}

public struct RadrootsMediaImportRequest: Sendable, Equatable, Hashable {
    public let allowedMediaKinds: [RadrootsMediaKind]
    public let selectionLimit: Int
    public let destinationScope: RadrootsFileScope

    public init(
        allowedMediaKinds: [RadrootsMediaKind] = [.image],
        selectionLimit: Int = 1,
        destinationScope: RadrootsFileScope = .temporary
    ) throws {
        self.allowedMediaKinds = try RadrootsCaptureIntakeValidation.normalizedMediaKinds(
            allowedMediaKinds,
            field: "media import"
        )
        self.selectionLimit = try RadrootsCaptureIntakeValidation.normalizedSelectionLimit(
            selectionLimit)
        self.destinationScope = destinationScope
    }
}

public struct RadrootsMediaCaptureRequest: Sendable, Equatable, Hashable {
    public let mediaKind: RadrootsMediaKind
    public let destinationScope: RadrootsFileScope

    public init(
        mediaKind: RadrootsMediaKind = .image,
        destinationScope: RadrootsFileScope = .temporary
    ) throws {
        self.mediaKind = mediaKind
        self.destinationScope = destinationScope
    }
}

public struct RadrootsMediaPickerSupport: Sendable, Equatable, Hashable {
    public let importAvailable: Bool
    public let cameraCaptureAvailable: Bool
    public let supportedImportKinds: [RadrootsMediaKind]
    public let supportedCaptureKinds: [RadrootsMediaKind]
    public let multipleSelectionSupported: Bool

    public init(
        importAvailable: Bool,
        cameraCaptureAvailable: Bool,
        supportedImportKinds: [RadrootsMediaKind],
        supportedCaptureKinds: [RadrootsMediaKind],
        multipleSelectionSupported: Bool
    ) throws {
        self.importAvailable = importAvailable
        self.cameraCaptureAvailable = cameraCaptureAvailable
        self.supportedImportKinds =
            importAvailable
            ? try RadrootsCaptureIntakeValidation.normalizedMediaKinds(
                supportedImportKinds, field: "media import support")
            : []
        self.supportedCaptureKinds =
            cameraCaptureAvailable
            ? try RadrootsCaptureIntakeValidation.normalizedMediaKinds(
                supportedCaptureKinds, field: "camera capture support")
            : []
        self.multipleSelectionSupported = multipleSelectionSupported
    }
}

public struct RadrootsMediaAsset: Sendable, Equatable, Hashable {
    public let source: RadrootsMediaSource
    public let kind: RadrootsMediaKind
    public let file: RadrootsFileReference
    public let mediaType: String
    public let suggestedFilename: String
    public let sizeBytes: UInt64
    public let pixelWidth: UInt32?
    public let pixelHeight: UInt32?
    public let capturedAt: Date

    public init(
        source: RadrootsMediaSource,
        kind: RadrootsMediaKind,
        file: RadrootsFileReference,
        mediaType: String,
        suggestedFilename: String,
        sizeBytes: UInt64,
        pixelWidth: UInt32? = nil,
        pixelHeight: UInt32? = nil,
        capturedAt: Date
    ) throws {
        self.source = source
        self.kind = kind
        self.file = file
        self.mediaType = try RadrootsCaptureIntakeValidation.normalizedMediaType(mediaType)
        self.suggestedFilename = try RadrootsCaptureIntakeValidation.normalizedFilename(
            suggestedFilename)
        self.sizeBytes = sizeBytes
        self.pixelWidth = try RadrootsCaptureIntakeValidation.normalizedDimension(
            pixelWidth, field: "pixel width")
        self.pixelHeight = try RadrootsCaptureIntakeValidation.normalizedDimension(
            pixelHeight, field: "pixel height")
        if self.pixelWidth == nil || self.pixelHeight == nil {
            guard self.pixelWidth == nil, self.pixelHeight == nil else {
                throw RadrootsCaptureIntakeError.invalidRequest
            }
        }
        self.capturedAt = try RadrootsCaptureIntakeValidation.normalizedDate(
            capturedAt, field: "captured timestamp")
    }
}

public struct RadrootsMediaImportResult: Sendable, Equatable, Hashable {
    public let items: [RadrootsMediaAsset]

    public init(items: [RadrootsMediaAsset]) throws {
        guard !items.isEmpty else {
            throw RadrootsCaptureIntakeError.invalidRequest
        }
        self.items = items
    }
}

public struct RadrootsMediaCaptureResult: Sendable, Equatable, Hashable {
    public let item: RadrootsMediaAsset

    public init(item: RadrootsMediaAsset) {
        self.item = item
    }
}

public protocol RadrootsMediaPicker: Sendable {
    func currentSupport() async throws -> RadrootsMediaPickerSupport
    func importMedia(_ request: RadrootsMediaImportRequest) async throws -> RadrootsMediaImportResult
    func captureMedia(_ request: RadrootsMediaCaptureRequest) async throws
        -> RadrootsMediaCaptureResult
}

public enum RadrootsDocumentScannerOutputKind: String, Sendable, Equatable, Hashable, CaseIterable {
    case pdf
}

public struct RadrootsDocumentScannerSupport: Sendable, Equatable, Hashable {
    public let interactiveScanAvailable: Bool
    public let multiPageSupported: Bool
    public let supportedOutputKinds: [RadrootsDocumentScannerOutputKind]

    public init(
        interactiveScanAvailable: Bool,
        multiPageSupported: Bool,
        supportedOutputKinds: [RadrootsDocumentScannerOutputKind]
    ) throws {
        self.interactiveScanAvailable = interactiveScanAvailable
        self.multiPageSupported = multiPageSupported && interactiveScanAvailable
        self.supportedOutputKinds =
            interactiveScanAvailable
            ? try RadrootsCaptureIntakeValidation.normalizedScannerOutputKinds(supportedOutputKinds)
            : []
    }
}

public struct RadrootsDocumentScanRequest: Sendable, Equatable, Hashable {
    public let outputKind: RadrootsDocumentScannerOutputKind
    public let destinationScope: RadrootsFileScope

    public init(
        outputKind: RadrootsDocumentScannerOutputKind = .pdf,
        destinationScope: RadrootsFileScope = .temporary
    ) {
        self.outputKind = outputKind
        self.destinationScope = destinationScope
    }
}

public struct RadrootsScannedDocument: Sendable, Equatable, Hashable {
    public let file: RadrootsFileReference
    public let outputKind: RadrootsDocumentScannerOutputKind
    public let suggestedFilename: String
    public let mediaType: String
    public let pageCount: UInt16
    public let sizeBytes: UInt64
    public let capturedAt: Date

    public init(
        file: RadrootsFileReference,
        outputKind: RadrootsDocumentScannerOutputKind,
        suggestedFilename: String,
        mediaType: String,
        pageCount: UInt16,
        sizeBytes: UInt64,
        capturedAt: Date
    ) throws {
        self.file = file
        self.outputKind = outputKind
        self.suggestedFilename = try RadrootsCaptureIntakeValidation.normalizedFilename(
            suggestedFilename)
        self.mediaType = try RadrootsCaptureIntakeValidation.normalizedMediaType(mediaType)
        guard pageCount > 0 else {
            throw RadrootsCaptureIntakeError.invalidRequest
        }
        self.pageCount = pageCount
        self.sizeBytes = sizeBytes
        self.capturedAt = try RadrootsCaptureIntakeValidation.normalizedDate(
            capturedAt, field: "scanned document timestamp")
    }
}

public protocol RadrootsDocumentScanner: Sendable {
    func currentSupport() async throws -> RadrootsDocumentScannerSupport
    func scanDocument(_ request: RadrootsDocumentScanRequest) async throws -> RadrootsScannedDocument
}

public enum RadrootsCaptureIntakeValidation {
    public static func normalizedMediaKinds(_ kinds: [RadrootsMediaKind], field: String) throws
        -> [RadrootsMediaKind]
    {
        var seen = Set<RadrootsMediaKind>()
        let normalized = kinds.filter { kind in
            if seen.contains(kind) {
                return false
            }
            seen.insert(kind)
            return true
        }
        guard !normalized.isEmpty else {
            throw RadrootsCaptureIntakeError.invalidRequest
        }
        return normalized
    }

    public static func normalizedSelectionLimit(_ selectionLimit: Int) throws -> Int {
        guard selectionLimit > 0 else {
            throw RadrootsCaptureIntakeError.invalidRequest
        }
        guard selectionLimit <= 100 else {
            throw RadrootsCaptureIntakeError.invalidRequest
        }
        return selectionLimit
    }

    public static func normalizedScannerOutputKinds(
        _ outputKinds: [RadrootsDocumentScannerOutputKind]
    ) throws -> [RadrootsDocumentScannerOutputKind] {
        var seen = Set<RadrootsDocumentScannerOutputKind>()
        let normalized = outputKinds.filter { outputKind in
            if seen.contains(outputKind) {
                return false
            }
            seen.insert(outputKind)
            return true
        }
        guard !normalized.isEmpty else {
            throw RadrootsCaptureIntakeError.invalidRequest
        }
        return normalized
    }

    public static func normalizedFilename(_ filename: String) throws -> String {
        let trimmed = filename.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw RadrootsCaptureIntakeError.invalidRequest
        }
        guard trimmed != ".", trimmed != ".." else {
            throw RadrootsCaptureIntakeError.invalidRequest
        }
        guard !NSString(string: trimmed).isAbsolutePath else {
            throw RadrootsCaptureIntakeError.invalidRequest
        }
        guard !trimmed.contains("/"), !trimmed.contains("\\"), !trimmed.contains("\0") else {
            throw RadrootsCaptureIntakeError.invalidRequest
        }
        guard trimmed.rangeOfCharacter(from: .controlCharacters) == nil else {
            throw RadrootsCaptureIntakeError.invalidRequest
        }
        guard trimmed.utf8.count <= 255 else {
            throw RadrootsCaptureIntakeError.invalidRequest
        }
        return trimmed
    }

    public static func normalizedMediaType(_ mediaType: String) throws -> String {
        let trimmed = mediaType.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw RadrootsCaptureIntakeError.invalidRequest
        }
        guard trimmed.rangeOfCharacter(from: .whitespacesAndNewlines.union(.controlCharacters)) == nil
        else {
            throw RadrootsCaptureIntakeError.invalidRequest
        }
        let parts = trimmed.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 2, parts.allSatisfy({ !$0.isEmpty }) else {
            throw RadrootsCaptureIntakeError.invalidRequest
        }
        return trimmed.lowercased()
    }

    public static func normalizedDimension(_ dimension: UInt32?, field: String) throws -> UInt32? {
        guard let dimension else {
            return nil
        }
        guard dimension > 0 else {
            throw RadrootsCaptureIntakeError.invalidRequest
        }
        return dimension
    }

    public static func normalizedDate(_ date: Date, field: String) throws -> Date {
        guard date.timeIntervalSinceReferenceDate.isFinite else {
            throw RadrootsCaptureIntakeError.invalidRequest
        }
        return date
    }
}
