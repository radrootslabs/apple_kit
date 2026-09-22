import Darwin
import Foundation

/// Module-internal mechanics shared by the file owner; no public API.
extension RadrootsAppleFileAccess {
    func stagedBlobURL(for blob: RadrootsStagedBlobReference) throws -> URL {
        try roots.stagedBlobURL(for: blob)
    }

    var preparedExportsRoot: URL {
        roots.temporaryRoot.appendingPathComponent("prepared_exports", isDirectory: true)
            .standardizedFileURL
    }

    func preparedExportDirectoryURL(for preparedExport: RadrootsPreparedExportDocument) throws -> URL {
        let normalizedPreparedID = try RadrootsPreparedExportDocument.normalizedPreparedID(
            preparedExport.preparedID
        )
        let directoryURL = preparedExportsRoot.appendingPathComponent(
            normalizedPreparedID, isDirectory: true
        ).standardizedFileURL
        guard preparedExport.fileURL.standardizedFileURL.path.hasPrefix(directoryURL.path + "/") else {
            throw RadrootsAppleFileError.invalidRequest
        }
        return directoryURL
    }

    func stageFileURL(
        _ sourceURL: URL,
        mediaType: String?,
        filenameHint: String?
    ) throws -> RadrootsStagedBlobReference {
        let sizeBytes = try fileSizeInt(at: sourceURL)
        guard sizeBytes <= Self.maximumGovernedFileBytes else {
            throw RadrootsAppleFileError.permanentFailure
        }
        let blobID = UUID().uuidString.lowercased()
        let blob = try RadrootsStagedBlobReference(
            blobID: blobID,
            sizeBytes: sizeBytes,
            mediaType: mediaType,
            filenameHint: filenameHint
        )
        try installStagedBlob(readExternalBytes(sourceURL), reference: blob)
        return blob
    }

    func withSecurityScopedFile<T>(_ sourceURL: URL, _ body: (URL) throws -> T) throws -> T {
        guard sourceURL.isFileURL else {
            throw RadrootsAppleFileError.invalidRequest
        }
        let scopedURL = sourceURL.standardizedFileURL
        var isDirectory = ObjCBool(false)
        guard fileManager.fileExists(atPath: scopedURL.path, isDirectory: &isDirectory) else {
            throw RadrootsAppleFileError.notFound
        }
        guard !isDirectory.boolValue else {
            throw RadrootsAppleFileError.invalidRequest
        }
        let didStartScope = scopedURL.startAccessingSecurityScopedResource()
        defer {
            if didStartScope {
                scopedURL.stopAccessingSecurityScopedResource()
            }
        }
        return try body(scopedURL)
    }

    func copyReplacingItem(from sourceURL: URL, to destinationURL: URL) throws {
        guard sourceURL.isFileURL, destinationURL.isFileURL else {
            throw RadrootsAppleFileError.invalidRequest
        }
        try RadrootsAtomicFile.install(readExternalBytes(sourceURL), at: destinationURL)
    }

    func readExternalBytes(_ sourceURL: URL) throws -> Data {
        // The caller holds the user's security-scoped URL grant. Canonicalize
        // that explicit external parent, then retain the validated file bytes
        // through installation; do not copy a changing pathname or a symlink.
        guard let pointer = sourceURL.deletingLastPathComponent().path.withCString({ Darwin.realpath($0, nil) }) else {
            throw RadrootsAppleFileError.permanentFailure
        }
        defer { Darwin.free(pointer) }
        let parent = URL(fileURLWithPath: String(cString: pointer), isDirectory: true)
        do {
            return try RadrootsGovernedFileReader.read(
                root: parent, relativePath: sourceURL.lastPathComponent, maximumBytes: Self.maximumGovernedFileBytes
            )
        } catch { throw RadrootsAppleFileError.permanentFailure }
    }

    func createParentDirectory(for url: URL) throws {
        try classifiedFileSystemOperation {
            try fileManager.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true
            )
        }
    }

    func fileSize(at url: URL) throws -> Int {
        try fileSizeInt(at: url)
    }

    func fileSizeInt(at url: URL) throws -> Int {
        let values = try classifiedFileSystemOperation {
            try url.resourceValues(forKeys: [.fileSizeKey])
        }
        guard let size = values.fileSize else {
            throw RadrootsAppleFileError.permanentFailure
        }
        return size
    }

    func fileSizeUInt64(at url: URL) throws -> UInt64 {
        try UInt64(fileSizeInt(at: url))
    }

    func readGovernedFile(
        _ file: RadrootsFileReference,
        maximumBytes: Int,
        preserveTooLarge: Bool = false
    ) throws -> Data {
        guard (0 ... Self.maximumGovernedFileBytes).contains(maximumBytes) else {
            throw RadrootsAppleFileError.invalidRequest
        }
        let root = roots.root(for: file.scope)
        let resolved = try roots.resolvedURL(for: file)
        let relative = try relativePath(for: resolved, under: root)
        do {
            return try RadrootsGovernedFileReader.read(
                root: root,
                relativePath: relative,
                maximumBytes: maximumBytes
            )
        } catch let error as RadrootsGovernedFileReadError {
            if preserveTooLarge, error == .tooLarge {
                throw error
            }
            throw mappedGovernedReadError(error)
        }
    }

    func mappedGovernedReadError(_ error: RadrootsGovernedFileReadError) -> RadrootsAppleFileError {
        switch error {
        case .unavailable:
            .notFound
        case .invalidRequest:
            .invalidRequest
        case .tooLarge:
            .permanentFailure
        case .invalidObject, .changedDuringRead, .ioFailure:
            .permanentFailure
        }
    }

    func relativePath(for url: URL, under rootURL: URL) throws -> String {
        let rootPath = rootURL.path
        let filePath = url.path
        guard filePath.hasPrefix(rootPath + "/") else {
            throw RadrootsAppleFileError.invalidRequest
        }
        return String(filePath.dropFirst(rootPath.count + 1))
    }

    func classifiedFileSystemOperation<T>(_ operation: () throws -> T) throws -> T {
        do {
            return try operation()
        } catch let error as RadrootsAppleFileError {
            throw error
        } catch let error as RadrootsDocumentInterchangeError {
            throw error
        } catch {
            throw RadrootsAppleFileError.classified(error)
        }
    }
}
