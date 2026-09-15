import Darwin
import Foundation

public final class RadrootsAppleFileAccess: RadrootsFileAccess {
    static let maximumGovernedFileBytes = 512 * 1024 * 1024

    public let roots: RadrootsAppleFileRoots
    let fileManager: FileManager

    public init(roots: RadrootsAppleFileRoots, fileManager: FileManager = .default) {
        self.roots = roots
        self.fileManager = fileManager
    }

    public func write(_ payload: RadrootsFilePayload, to file: RadrootsFileReference) throws {
        let url = try roots.resolvedURL(for: file)
        try createParentDirectory(for: url)
        switch payload {
        case let .inline(inlineData):
            try classifiedFileSystemOperation {
                try inlineData.write(to: url, options: [.atomic])
            }
        case let .stagedBlob(stagedBlob):
            let data = try readStagedBlob(stagedBlob)
            try classifiedFileSystemOperation {
                try data.write(to: url, options: [.atomic])
            }
        }
    }

    public func read(
        _ file: RadrootsFileReference, mode: RadrootsFileReadMode
    ) throws -> RadrootsFileReadResult {
        switch mode {
        case let .inline(maxBytes):
            return try .inline(readGovernedFile(file, maximumBytes: maxBytes))
        case let .preferInline(maxBytes):
            do {
                return try .inline(
                    readGovernedFile(file, maximumBytes: maxBytes, preserveTooLarge: true)
                )
            } catch RadrootsGovernedFileReadError.tooLarge {
                let url = try roots.resolvedURL(for: file)
                let staged = try stageFile(file, mediaType: nil, filenameHint: url.lastPathComponent)
                return .stagedBlob(staged)
            }
        case .stagedBlob:
            let url = try roots.resolvedURL(for: file)
            let staged = try stageFile(file, mediaType: nil, filenameHint: url.lastPathComponent)
            return .stagedBlob(staged)
        }
    }

    public func delete(_ file: RadrootsFileReference) throws {
        let url = try roots.resolvedURL(for: file)
        guard fileManager.fileExists(atPath: url.path) else {
            return
        }
        try classifiedFileSystemOperation {
            try fileManager.removeItem(at: url)
        }
    }

    public func list(_ directory: RadrootsFileReference) throws -> [RadrootsFileEntry] {
        let rootURL = roots.root(for: directory.scope).standardizedFileURL
        let directoryURL = try roots.resolvedURL(for: directory, allowRootDirectory: true)
        var isDirectory = ObjCBool(false)
        guard fileManager.fileExists(atPath: directoryURL.path, isDirectory: &isDirectory) else {
            return []
        }
        guard isDirectory.boolValue else {
            throw RadrootsAppleFileError.invalidRequest
        }
        return try classifiedFileSystemOperation {
            let urls = try fileManager.contentsOfDirectory(
                at: directoryURL,
                includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey],
                options: []
            )
            return try urls.map { url in
                let values = try url.resourceValues(
                    forKeys: [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey]
                )
                let relativePath = try relativePath(for: url.standardizedFileURL, under: rootURL)
                return RadrootsFileEntry(
                    file: RadrootsFileReference(scope: directory.scope, relativePath: relativePath),
                    name: url.lastPathComponent,
                    isDirectory: values.isDirectory ?? false,
                    sizeBytes: values.fileSize,
                    modifiedAt: values.contentModificationDate
                )
            }
            .sorted { left, right in
                left.file.relativePath < right.file.relativePath
            }
        }
    }

    public func reset(scope: RadrootsFileScope) throws {
        let url = roots.root(for: scope)
        try classifiedFileSystemOperation {
            if fileManager.fileExists(atPath: url.path) {
                try fileManager.removeItem(at: url)
            }
            try fileManager.createDirectory(at: url, withIntermediateDirectories: true)
        }
    }
}

public extension RadrootsAppleFileAccess {
    @discardableResult
    func stageBlob(
        _ data: Data,
        mediaType: String? = nil,
        filenameHint: String? = nil
    ) throws -> RadrootsStagedBlobReference {
        guard data.count <= Self.maximumGovernedFileBytes else {
            throw RadrootsAppleFileError.invalidRequest
        }
        let blobID = UUID().uuidString.lowercased()
        let blob = try RadrootsStagedBlobReference(
            blobID: blobID,
            sizeBytes: data.count,
            mediaType: mediaType,
            filenameHint: filenameHint
        )
        try installStagedBlob(data, reference: blob)
        return blob
    }

    @discardableResult
    func stageFile(
        _ file: RadrootsFileReference,
        mediaType: String? = nil,
        filenameHint: String? = nil
    ) throws -> RadrootsStagedBlobReference {
        let sourceURL = try roots.resolvedURL(for: file)
        return try stageBlob(
            readGovernedFile(file, maximumBytes: Self.maximumGovernedFileBytes),
            mediaType: mediaType,
            filenameHint: filenameHint ?? sourceURL.lastPathComponent
        )
    }

    @discardableResult
    func stageExternalFile(
        _ sourceURL: URL,
        mediaType: String? = nil,
        filenameHint: String? = nil
    ) throws -> RadrootsStagedBlobReference {
        try withSecurityScopedFile(sourceURL) { scopedURL in
            try stageFileURL(
                scopedURL,
                mediaType: mediaType,
                filenameHint: filenameHint ?? scopedURL.lastPathComponent
            )
        }
    }

    @discardableResult
    func copyExternalFile(
        _ sourceURL: URL,
        to file: RadrootsFileReference,
        mediaType: String? = nil,
        suggestedFilename: String? = nil
    ) throws -> RadrootsImportedDocument {
        try withSecurityScopedFile(sourceURL) { scopedURL in
            let destinationURL = try roots.resolvedURL(for: file)
            try createParentDirectory(for: destinationURL)
            try copyReplacingItem(from: scopedURL, to: destinationURL)
            let sizeBytes = try fileSizeUInt64(at: destinationURL)
            return try RadrootsImportedDocument(
                file: file,
                originalURL: scopedURL,
                suggestedFilename: suggestedFilename ?? scopedURL.lastPathComponent,
                mediaType: mediaType,
                sizeBytes: sizeBytes
            )
        }
    }

    @discardableResult
    func prepareExport(
        _ request: RadrootsExportDocumentRequest
    ) throws -> RadrootsPreparedExportDocument {
        let preparedID = UUID().uuidString.lowercased()
        let directoryURL = preparedExportsRoot.appendingPathComponent(preparedID, isDirectory: true)
        let fileURL = directoryURL.appendingPathComponent(request.suggestedFilename).standardizedFileURL
        try classifiedFileSystemOperation {
            try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        }
        let preparedData: Data = switch request.source {
        case let .inlineData(data):
            data
        case let .file(file):
            try readGovernedFile(file, maximumBytes: Self.maximumGovernedFileBytes)
        case let .stagedBlob(stagedBlob):
            try readStagedBlob(stagedBlob)
        }
        try classifiedFileSystemOperation {
            try preparedData.write(to: fileURL, options: [.atomic])
        }
        let sizeBytes: UInt64 =
            if let requestSizeBytes = request.sizeBytes {
                requestSizeBytes
            } else {
                try fileSizeUInt64(at: fileURL)
            }
        return try RadrootsPreparedExportDocument(
            preparedID: preparedID,
            fileURL: fileURL,
            suggestedFilename: request.suggestedFilename,
            mediaType: request.mediaType,
            sizeBytes: sizeBytes
        )
    }

    func readStagedBlob(_ blob: RadrootsStagedBlobReference) throws -> Data {
        guard (0 ... Self.maximumGovernedFileBytes).contains(blob.sizeBytes) else {
            throw RadrootsAppleFileError.invalidRequest
        }
        let data: Data
        do {
            data = try RadrootsGovernedFileReader.read(
                root: roots.stagedBlobsRoot,
                relativePath: blob.blobID,
                maximumBytes: blob.sizeBytes
            )
        } catch let error as RadrootsGovernedFileReadError {
            throw mappedGovernedReadError(error)
        }
        guard data.count == blob.sizeBytes else {
            throw RadrootsAppleFileError.permanentFailure
        }
        return data
    }

    func releaseStagedBlob(_ blob: RadrootsStagedBlobReference) throws {
        let url = try stagedBlobURL(for: blob)
        if fileManager.fileExists(atPath: url.path) {
            try classifiedFileSystemOperation {
                try fileManager.removeItem(at: url)
            }
        }
    }

    func preparedExportExists(_ preparedExport: RadrootsPreparedExportDocument) throws -> Bool {
        let directoryURL = try preparedExportDirectoryURL(for: preparedExport)
        return fileManager.fileExists(atPath: directoryURL.path)
            && fileManager.fileExists(atPath: preparedExport.fileURL.path)
    }

    func releasePreparedExport(_ preparedExport: RadrootsPreparedExportDocument) throws {
        let directoryURL = try preparedExportDirectoryURL(for: preparedExport)
        if fileManager.fileExists(atPath: directoryURL.path) {
            try classifiedFileSystemOperation {
                try fileManager.removeItem(at: directoryURL)
            }
        }
    }

    @discardableResult
    func sweepStagedBlobs(olderThan cutoff: Date) throws -> [RadrootsStagedBlobReference] {
        guard fileManager.fileExists(atPath: roots.stagedBlobsRoot.path) else {
            return []
        }
        return try classifiedFileSystemOperation {
            let urls = try fileManager.contentsOfDirectory(
                at: roots.stagedBlobsRoot,
                includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey],
                options: []
            )
            var released: [RadrootsStagedBlobReference] = []
            for url in urls {
                // Interrupted atomic outputs are identifiable orphans, not valid
                // blob references. Their owner reconciles them separately.
                guard !url.lastPathComponent.hasPrefix(".radroots_pending_") else { continue }
                let values = try url.resourceValues(
                    forKeys: [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey]
                )
                guard values.isDirectory != true else {
                    continue
                }
                guard let modifiedAt = values.contentModificationDate, modifiedAt < cutoff else {
                    continue
                }
                let blob = try RadrootsStagedBlobReference(
                    blobID: url.lastPathComponent,
                    sizeBytes: values.fileSize ?? 0
                )
                try fileManager.removeItem(at: url)
                released.append(blob)
            }
            return released.sorted { left, right in
                left.blobID < right.blobID
            }
        }
    }

    func resetStagedBlobs() throws {
        try classifiedFileSystemOperation {
            if fileManager.fileExists(atPath: roots.stagedBlobsRoot.path) {
                try fileManager.removeItem(at: roots.stagedBlobsRoot)
            }
            try fileManager.createDirectory(at: roots.stagedBlobsRoot, withIntermediateDirectories: true)
        }
    }

    func resetFileRoots() throws {
        for scope in RadrootsFileScope.allCases {
            try reset(scope: scope)
        }
        try resetStagedBlobs()
    }
}
