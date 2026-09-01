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
            charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_")
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

public final class RadrootsAppleFileAccess: RadrootsFileAccess {
    private static let maximumGovernedFileBytes = 512 * 1024 * 1024

    public let roots: RadrootsAppleFileRoots
    private let fileManager: FileManager

    public init(roots: RadrootsAppleFileRoots, fileManager: FileManager = .default) {
        self.roots = roots
        self.fileManager = fileManager
    }

    public func write(_ payload: RadrootsFilePayload, to file: RadrootsFileReference) throws {
        let url = try roots.resolvedURL(for: file)
        try createParentDirectory(for: url)
        switch payload {
        case .inline(let inlineData):
            try classifiedFileSystemOperation {
            try inlineData.write(to: url, options: [.atomic])
            }
        case .stagedBlob(let stagedBlob):
            let data = try readStagedBlob(stagedBlob)
            try classifiedFileSystemOperation {
                try data.write(to: url, options: [.atomic])
            }
        }
    }

    public func read(_ file: RadrootsFileReference, mode: RadrootsFileReadMode) throws
        -> RadrootsFileReadResult
    {
        switch mode {
        case .inline(let maxBytes):
            return try .inline(readGovernedFile(file, maximumBytes: maxBytes))
        case .preferInline(let maxBytes):
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

    @discardableResult
    public func stageBlob(
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
        let url = try stagedBlobURL(for: blob)
        try classifiedFileSystemOperation {
        try fileManager.createDirectory(at: roots.stagedBlobsRoot, withIntermediateDirectories: true)
        try data.write(to: url, options: [.atomic])
        }
        return blob
    }

    @discardableResult
    public func stageFile(
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
    public func stageExternalFile(
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
    public func copyExternalFile(
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
    public func prepareExport(_ request: RadrootsExportDocumentRequest) throws
        -> RadrootsPreparedExportDocument
    {
        let preparedID = UUID().uuidString.lowercased()
        let directoryURL = preparedExportsRoot.appendingPathComponent(preparedID, isDirectory: true)
        let fileURL = directoryURL.appendingPathComponent(request.suggestedFilename).standardizedFileURL
        try classifiedFileSystemOperation {
        try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        }
        let preparedData: Data
        switch request.source {
        case .inlineData(let data):
            preparedData = data
        case .file(let file):
            preparedData = try readGovernedFile(file, maximumBytes: Self.maximumGovernedFileBytes)
        case .stagedBlob(let stagedBlob):
            preparedData = try readStagedBlob(stagedBlob)
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

    public func readStagedBlob(_ blob: RadrootsStagedBlobReference) throws -> Data {
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

    public func releaseStagedBlob(_ blob: RadrootsStagedBlobReference) throws {
        let url = try stagedBlobURL(for: blob)
        if fileManager.fileExists(atPath: url.path) {
            try classifiedFileSystemOperation {
            try fileManager.removeItem(at: url)
        }
    }
    }

    public func preparedExportExists(_ preparedExport: RadrootsPreparedExportDocument) throws -> Bool {
        let directoryURL = try preparedExportDirectoryURL(for: preparedExport)
        return fileManager.fileExists(atPath: directoryURL.path)
            && fileManager.fileExists(atPath: preparedExport.fileURL.path)
    }

    public func releasePreparedExport(_ preparedExport: RadrootsPreparedExportDocument) throws {
        let directoryURL = try preparedExportDirectoryURL(for: preparedExport)
        if fileManager.fileExists(atPath: directoryURL.path) {
            try classifiedFileSystemOperation {
            try fileManager.removeItem(at: directoryURL)
        }
    }
    }

    @discardableResult
    public func sweepStagedBlobs(olderThan cutoff: Date) throws -> [RadrootsStagedBlobReference] {
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

    public func resetStagedBlobs() throws {
        try classifiedFileSystemOperation {
        if fileManager.fileExists(atPath: roots.stagedBlobsRoot.path) {
            try fileManager.removeItem(at: roots.stagedBlobsRoot)
        }
        try fileManager.createDirectory(at: roots.stagedBlobsRoot, withIntermediateDirectories: true)
    }
    }

    public func resetFileRoots() throws {
        for scope in RadrootsFileScope.allCases {
            try reset(scope: scope)
        }
        try resetStagedBlobs()
    }

    private func stagedBlobURL(for blob: RadrootsStagedBlobReference) throws -> URL {
        try roots.stagedBlobURL(for: blob)
    }

    private var preparedExportsRoot: URL {
        roots.temporaryRoot.appendingPathComponent("prepared_exports", isDirectory: true)
            .standardizedFileURL
    }

    private func preparedExportDirectoryURL(for preparedExport: RadrootsPreparedExportDocument) throws
        -> URL
    {
        let normalizedPreparedID = try RadrootsPreparedExportDocument.normalizedPreparedID(
            preparedExport.preparedID)
        let directoryURL = preparedExportsRoot.appendingPathComponent(
            normalizedPreparedID, isDirectory: true
        ).standardizedFileURL
        guard preparedExport.fileURL.standardizedFileURL.path.hasPrefix(directoryURL.path + "/") else {
            throw RadrootsAppleFileError.invalidRequest
        }
        return directoryURL
    }

    private func stageFileURL(
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
        let destinationURL = try stagedBlobURL(for: blob)
        try classifiedFileSystemOperation {
        try fileManager.createDirectory(at: roots.stagedBlobsRoot, withIntermediateDirectories: true)
        }
        try copyReplacingItem(from: sourceURL, to: destinationURL)
        return blob
    }

    private func withSecurityScopedFile<T>(_ sourceURL: URL, _ body: (URL) throws -> T) throws -> T {
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

    private func copyReplacingItem(from sourceURL: URL, to destinationURL: URL) throws {
        guard sourceURL.isFileURL, destinationURL.isFileURL else {
            throw RadrootsAppleFileError.invalidRequest
        }
        try createParentDirectory(for: destinationURL)
        try classifiedFileSystemOperation {
        if fileManager.fileExists(atPath: destinationURL.path) {
            try fileManager.removeItem(at: destinationURL)
        }
        try fileManager.copyItem(at: sourceURL, to: destinationURL)
    }
    }

    private func createParentDirectory(for url: URL) throws {
        try classifiedFileSystemOperation {
            try fileManager.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        }
    }

    private func fileSize(at url: URL) throws -> Int {
        try fileSizeInt(at: url)
    }

    private func fileSizeInt(at url: URL) throws -> Int {
        let values = try classifiedFileSystemOperation {
            try url.resourceValues(forKeys: [.fileSizeKey])
        }
        guard let size = values.fileSize else {
            throw RadrootsAppleFileError.permanentFailure
        }
        return size
    }

    private func fileSizeUInt64(at url: URL) throws -> UInt64 {
        try UInt64(fileSizeInt(at: url))
    }

    private func readGovernedFile(
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

    private func mappedGovernedReadError(_ error: RadrootsGovernedFileReadError)
        -> RadrootsAppleFileError
    {
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

    private func relativePath(for url: URL, under rootURL: URL) throws -> String {
        let rootPath = rootURL.standardizedFileURL.path
        let filePath = url.standardizedFileURL.path
        guard filePath.hasPrefix(rootPath + "/") else {
            throw RadrootsAppleFileError.invalidRequest
        }
        return String(filePath.dropFirst(rootPath.count + 1))
    }

    private func classifiedFileSystemOperation<T>(_ operation: () throws -> T) throws -> T {
        do {
            return try operation()
        } catch let error as RadrootsAppleFileError {
            throw error
        } catch let error as RadrootsDocumentInterchangeError {
            throw error
        } catch {
            throw RadrootsAppleFileError.permanentFailure
        }
    }
}

public struct RadrootsAppleFileRoots: Sendable, Equatable {
    public let appIdentifier: String
    public let dataRoot: URL
    public let cacheRoot: URL
    public let temporaryRoot: URL
    public let logsRoot: URL
    public let stagedBlobsRoot: URL

    public init(
        appIdentifier: String,
        dataRoot: URL,
        cacheRoot: URL,
        temporaryRoot: URL,
        logsRoot: URL? = nil,
        stagedBlobsRoot: URL? = nil
    ) throws {
        let normalizedAppIdentifier = try Self.normalizedAppIdentifier(appIdentifier)
        let normalizedDataRoot = try Self.normalizedRootURL(dataRoot, field: "dataRoot")
        let normalizedCacheRoot = try Self.normalizedRootURL(cacheRoot, field: "cacheRoot")
        let normalizedTemporaryRoot = try Self.normalizedRootURL(temporaryRoot, field: "temporaryRoot")
        self.appIdentifier = normalizedAppIdentifier
        self.dataRoot = normalizedDataRoot
        self.cacheRoot = normalizedCacheRoot
        self.temporaryRoot = normalizedTemporaryRoot
        self.logsRoot = try Self.normalizedRootURL(
            logsRoot ?? normalizedCacheRoot.appendingPathComponent("Logs", isDirectory: true),
            field: "logsRoot"
        )
        self.stagedBlobsRoot = try Self.normalizedRootURL(
            stagedBlobsRoot
                ?? normalizedTemporaryRoot.appendingPathComponent("staged_blobs", isDirectory: true),
            field: "stagedBlobsRoot"
        )
    }

    public static func appContainer(
        appIdentifier: String,
        fileManager: FileManager = .default
    ) throws -> Self {
        do {
        let normalizedAppIdentifier = try normalizedAppIdentifier(appIdentifier)
            let dataBaseURL = try canonicalExistingDirectory(
                fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        ))
            let cacheBaseURL = try canonicalExistingDirectory(
                fileManager.url(
            for: .cachesDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        ))
        let dataRoot = dataBaseURL.appendingPathComponent(normalizedAppIdentifier, isDirectory: true)
            let cacheRoot = cacheBaseURL.appendingPathComponent(
                normalizedAppIdentifier, isDirectory: true)
        let temporaryRoot = try canonicalExistingDirectory(fileManager.temporaryDirectory)
            .appendingPathComponent(normalizedAppIdentifier, isDirectory: true)
        return try Self(
            appIdentifier: normalizedAppIdentifier,
            dataRoot: dataRoot,
            cacheRoot: cacheRoot,
            temporaryRoot: temporaryRoot
        )
        } catch let error as RadrootsAppleFileError {
            throw error
        } catch {
            throw RadrootsAppleFileError.permanentFailure
        }
    }

    public func root(for scope: RadrootsFileScope) -> URL {
        switch scope {
        case .data:
            dataRoot
        case .cache:
            cacheRoot
        case .temporary:
            temporaryRoot
        case .logs:
            logsRoot
        }
    }

    public func resolvedURL(
        for file: RadrootsFileReference,
        allowRootDirectory: Bool = false
    ) throws -> URL {
        let rootURL = root(for: file.scope).standardizedFileURL
        let trimmedPath = file.relativePath.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedPath.isEmpty {
            if allowRootDirectory {
                return rootURL
            }
            throw RadrootsAppleFileError.invalidRequest
        }
        if NSString(string: trimmedPath).isAbsolutePath {
            throw RadrootsAppleFileError.invalidRequest
        }

        let candidateURL = rootURL.appendingPathComponent(trimmedPath).standardizedFileURL
        if candidateURL.path == rootURL.path {
            if allowRootDirectory {
                return candidateURL
            }
            throw RadrootsAppleFileError.invalidRequest
        }
        guard candidateURL.path.hasPrefix(rootURL.path + "/") else {
            throw RadrootsAppleFileError.invalidRequest
        }
        return candidateURL
    }

    public func stagedBlobURL(for blob: RadrootsStagedBlobReference) throws -> URL {
        let normalizedBlobID = try RadrootsStagedBlobReference.normalizedBlobID(blob.blobID)
        return stagedBlobsRoot.appendingPathComponent(normalizedBlobID).standardizedFileURL
    }

    public static func normalizedAppIdentifier(_ appIdentifier: String) throws -> String {
        let trimmed = appIdentifier.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw RadrootsAppleFileError.invalidRequest
        }
        return trimmed
    }

    public static func normalizedRootURL(_ rootURL: URL, field: String) throws -> URL {
        guard rootURL.isFileURL else {
            throw RadrootsAppleFileError.invalidRequest
        }
        let standardized = rootURL.standardizedFileURL
        guard standardized.path.hasPrefix("/") else {
            throw RadrootsAppleFileError.invalidRequest
        }
        return standardized
    }

    private static func canonicalExistingDirectory(_ directory: URL) throws -> URL {
        guard directory.isFileURL,
              let pointer = directory.path.withCString({ Darwin.realpath($0, nil) })
        else {
            throw RadrootsAppleFileError.permanentFailure
        }
        defer { Darwin.free(pointer) }
        return URL(fileURLWithPath: String(cString: pointer), isDirectory: true)
    }
}
