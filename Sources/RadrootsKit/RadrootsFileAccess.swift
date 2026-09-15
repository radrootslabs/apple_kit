import Darwin
import Foundation

public enum RadrootsFileScope: Sendable, Equatable, CaseIterable, Codable {
    case data
    case cache
    case temporary
    case logs
}

public struct RadrootsFileReference: Sendable, Equatable, Hashable, Codable {
    public let scope: RadrootsFileScope
    public let relativePath: String

    public init(scope: RadrootsFileScope, relativePath: String) {
        self.scope = scope
        self.relativePath = relativePath
    }
}

public struct RadrootsFileEntry: Sendable, Equatable, Hashable {
    public let file: RadrootsFileReference
    public let name: String
    public let isDirectory: Bool
    public let sizeBytes: Int?
    public let modifiedAt: Date?

    public init(
        file: RadrootsFileReference,
        name: String,
        isDirectory: Bool,
        sizeBytes: Int?,
        modifiedAt: Date?
    ) {
        self.file = file
        self.name = name
        self.isDirectory = isDirectory
        self.sizeBytes = sizeBytes
        self.modifiedAt = modifiedAt
    }
}

public struct RadrootsStagedBlobReference: Sendable, Equatable, Hashable, Codable {
    public let blobID: String
    public let sizeBytes: Int
    public let mediaType: String?
    public let filenameHint: String?

    public init(
        blobID: String,
        sizeBytes: Int,
        mediaType: String? = nil,
        filenameHint: String? = nil
    ) throws {
        let normalizedBlobID = try Self.normalizedBlobID(blobID)
        guard sizeBytes >= 0 else {
            throw RadrootsAppleFileError.invalidRequest
        }
        self.blobID = normalizedBlobID
        self.sizeBytes = sizeBytes
        self.mediaType = try Self.normalizedMediaType(mediaType)
        self.filenameHint = try Self.normalizedFilenameHint(filenameHint)
    }

    public static func normalizedBlobID(_ blobID: String) throws -> String {
        let trimmed = blobID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw RadrootsAppleFileError.invalidRequest
        }
        let allowed = CharacterSet(
            charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_"
        )
        guard trimmed.rangeOfCharacter(from: allowed.inverted) == nil else {
            throw RadrootsAppleFileError.invalidRequest
        }
        return trimmed
    }

    public static func normalizedMediaType(_ mediaType: String?) throws -> String? {
        guard let mediaType else {
            return nil
        }
        let trimmed = mediaType.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw RadrootsAppleFileError.invalidRequest
        }
        guard trimmed.rangeOfCharacter(from: .newlines) == nil else {
            throw RadrootsAppleFileError.invalidRequest
        }
        return trimmed
    }

    public static func normalizedFilenameHint(_ filenameHint: String?) throws -> String? {
        guard let filenameHint else {
            return nil
        }
        let trimmed = filenameHint.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw RadrootsAppleFileError.invalidRequest
        }
        guard !trimmed.contains("/"), !trimmed.contains("\\"), !trimmed.contains("\0") else {
            throw RadrootsAppleFileError.invalidRequest
        }
        return trimmed
    }
}

public enum RadrootsFilePayload: Sendable, Equatable {
    case inline(Data)
    case stagedBlob(RadrootsStagedBlobReference)
}

public enum RadrootsFileReadMode: Sendable, Equatable {
    case inline(maxBytes: Int)
    case preferInline(maxBytes: Int)
    case stagedBlob
}

public enum RadrootsFileReadResult: Sendable, Equatable {
    case inline(Data)
    case stagedBlob(RadrootsStagedBlobReference)
}

public protocol RadrootsFileAccess {
    func write(_ payload: RadrootsFilePayload, to file: RadrootsFileReference) throws
    func read(_ file: RadrootsFileReference, mode: RadrootsFileReadMode) throws
        -> RadrootsFileReadResult
    func delete(_ file: RadrootsFileReference) throws
    func list(_ directory: RadrootsFileReference) throws -> [RadrootsFileEntry]
    func reset(scope: RadrootsFileScope) throws
    @discardableResult func stageBlob(_ data: Data, mediaType: String?, filenameHint: String?) throws
        -> RadrootsStagedBlobReference
    @discardableResult func stageFile(
        _ file: RadrootsFileReference, mediaType: String?, filenameHint: String?
    ) throws -> RadrootsStagedBlobReference
    @discardableResult func stageExternalFile(
        _ sourceURL: URL, mediaType: String?, filenameHint: String?
    ) throws -> RadrootsStagedBlobReference
    @discardableResult func copyExternalFile(
        _ sourceURL: URL,
        to file: RadrootsFileReference,
        mediaType: String?,
        suggestedFilename: String?
    ) throws -> RadrootsImportedDocument
    @discardableResult func prepareExport(_ request: RadrootsExportDocumentRequest) throws
        -> RadrootsPreparedExportDocument
    func preparedExportExists(_ preparedExport: RadrootsPreparedExportDocument) throws -> Bool
    func readStagedBlob(_ blob: RadrootsStagedBlobReference) throws -> Data
    func releaseStagedBlob(_ blob: RadrootsStagedBlobReference) throws
    func releasePreparedExport(_ preparedExport: RadrootsPreparedExportDocument) throws
    @discardableResult func sweepStagedBlobs(olderThan cutoff: Date) throws
        -> [RadrootsStagedBlobReference]
    func resetStagedBlobs() throws
}
