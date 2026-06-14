import Foundation

public enum RadrootsFileScope: Sendable, Equatable, CaseIterable {
    case data
    case cache
    case temporary
    case logs
}

public struct RadrootsFileReference: Sendable, Equatable, Hashable {
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

public struct RadrootsStagedBlobReference: Sendable, Equatable, Hashable {
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
            throw RadrootsAppleFileError.invalidRequest("staged blob size cannot be negative")
        }
        self.blobID = normalizedBlobID
        self.sizeBytes = sizeBytes
        self.mediaType = try Self.normalizedMediaType(mediaType)
        self.filenameHint = try Self.normalizedFilenameHint(filenameHint)
    }

    public static func normalizedBlobID(_ blobID: String) throws -> String {
        let trimmed = blobID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw RadrootsAppleFileError.invalidRequest("staged blob id cannot be empty")
        }
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_")
        guard trimmed.rangeOfCharacter(from: allowed.inverted) == nil else {
            throw RadrootsAppleFileError.invalidRequest("staged blob id contains invalid characters")
        }
        return trimmed
    }

    public static func normalizedMediaType(_ mediaType: String?) throws -> String? {
        guard let mediaType else {
            return nil
        }
        let trimmed = mediaType.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw RadrootsAppleFileError.invalidRequest("staged blob media type cannot be empty")
        }
        guard trimmed.rangeOfCharacter(from: .newlines) == nil else {
            throw RadrootsAppleFileError.invalidRequest("staged blob media type cannot contain newlines")
        }
        return trimmed
    }

    public static func normalizedFilenameHint(_ filenameHint: String?) throws -> String? {
        guard let filenameHint else {
            return nil
        }
        let trimmed = filenameHint.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw RadrootsAppleFileError.invalidRequest("staged blob filename hint cannot be empty")
        }
        guard !trimmed.contains("/") && !trimmed.contains("\\") && !trimmed.contains("\0") else {
            throw RadrootsAppleFileError.invalidRequest("staged blob filename hint cannot contain path separators")
        }
        return trimmed
    }
}

public enum RadrootsFilePayload: Sendable, Equatable {
    case inline(Data)
    case stagedBlob(RadrootsStagedBlobReference)
}

public enum RadrootsFileReadMode: Sendable, Equatable {
    case inline
    case preferInline(maxBytes: Int)
    case stagedBlob
}

public enum RadrootsFileReadResult: Sendable, Equatable {
    case inline(Data)
    case stagedBlob(RadrootsStagedBlobReference)
}

public protocol RadrootsFileAccess {
    func write(_ payload: RadrootsFilePayload, to file: RadrootsFileReference) throws
    func read(_ file: RadrootsFileReference, mode: RadrootsFileReadMode) throws -> RadrootsFileReadResult
    func delete(_ file: RadrootsFileReference) throws
    func list(_ directory: RadrootsFileReference) throws -> [RadrootsFileEntry]
    func reset(scope: RadrootsFileScope) throws
    @discardableResult func stageBlob(_ data: Data, mediaType: String?, filenameHint: String?) throws -> RadrootsStagedBlobReference
    @discardableResult func stageFile(_ file: RadrootsFileReference, mediaType: String?, filenameHint: String?) throws -> RadrootsStagedBlobReference
    @discardableResult func stageExternalFile(_ sourceURL: URL, mediaType: String?, filenameHint: String?) throws -> RadrootsStagedBlobReference
    @discardableResult func copyExternalFile(
        _ sourceURL: URL,
        to file: RadrootsFileReference,
        mediaType: String?,
        suggestedFilename: String?
    ) throws -> RadrootsImportedDocument
    @discardableResult func prepareExport(_ request: RadrootsExportDocumentRequest) throws -> RadrootsPreparedExportDocument
    func readStagedBlob(_ blob: RadrootsStagedBlobReference) throws -> Data
    func releaseStagedBlob(_ blob: RadrootsStagedBlobReference) throws
    func releasePreparedExport(_ preparedExport: RadrootsPreparedExportDocument) throws
    @discardableResult func sweepStagedBlobs(olderThan cutoff: Date) throws -> [RadrootsStagedBlobReference]
    func resetStagedBlobs() throws
}

public final class RadrootsAppleFileAccess: RadrootsFileAccess {
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
            try inlineData.write(to: url, options: [.atomic])
        case .stagedBlob(let stagedBlob):
            try copyReplacingItem(from: try stagedBlobURL(for: stagedBlob), to: url)
        }
    }

    public func read(_ file: RadrootsFileReference, mode: RadrootsFileReadMode) throws -> RadrootsFileReadResult {
        let url = try roots.resolvedURL(for: file)
        guard fileManager.fileExists(atPath: url.path) else {
            throw RadrootsAppleFileError.notFound("file not found")
        }
        switch mode {
        case .inline:
            return .inline(try Data(contentsOf: url))
        case .preferInline(let maxBytes):
            guard maxBytes >= 0 else {
                throw RadrootsAppleFileError.invalidRequest("inline byte limit cannot be negative")
            }
            let size = try fileSize(at: url)
            if size <= maxBytes {
                return .inline(try Data(contentsOf: url))
            }
            let staged = try stageFile(file, mediaType: nil, filenameHint: url.lastPathComponent)
            return .stagedBlob(staged)
        case .stagedBlob:
            let staged = try stageFile(file, mediaType: nil, filenameHint: url.lastPathComponent)
            return .stagedBlob(staged)
        }
    }

    public func delete(_ file: RadrootsFileReference) throws {
        let url = try roots.resolvedURL(for: file)
        guard fileManager.fileExists(atPath: url.path) else {
            return
        }
        try fileManager.removeItem(at: url)
    }

    public func list(_ directory: RadrootsFileReference) throws -> [RadrootsFileEntry] {
        let rootURL = roots.root(for: directory.scope).standardizedFileURL
        let directoryURL = try roots.resolvedURL(for: directory, allowRootDirectory: true)
        var isDirectory = ObjCBool(false)
        guard fileManager.fileExists(atPath: directoryURL.path, isDirectory: &isDirectory) else {
            return []
        }
        guard isDirectory.boolValue else {
            throw RadrootsAppleFileError.invalidRequest("file list target must be a directory")
        }
        let urls = try fileManager.contentsOfDirectory(
            at: directoryURL,
            includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey],
            options: []
        )
        return try urls.map { url in
            let values = try url.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey])
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

    public func reset(scope: RadrootsFileScope) throws {
        let url = roots.root(for: scope)
        if fileManager.fileExists(atPath: url.path) {
            try fileManager.removeItem(at: url)
        }
        try fileManager.createDirectory(at: url, withIntermediateDirectories: true)
    }

    @discardableResult
    public func stageBlob(
        _ data: Data,
        mediaType: String? = nil,
        filenameHint: String? = nil
    ) throws -> RadrootsStagedBlobReference {
        let blobID = UUID().uuidString.lowercased()
        let blob = try RadrootsStagedBlobReference(
            blobID: blobID,
            sizeBytes: data.count,
            mediaType: mediaType,
            filenameHint: filenameHint
        )
        let url = try stagedBlobURL(for: blob)
        try fileManager.createDirectory(at: roots.stagedBlobsRoot, withIntermediateDirectories: true)
        try data.write(to: url, options: [.atomic])
        return blob
    }

    @discardableResult
    public func stageFile(
        _ file: RadrootsFileReference,
        mediaType: String? = nil,
        filenameHint: String? = nil
    ) throws -> RadrootsStagedBlobReference {
        let sourceURL = try roots.resolvedURL(for: file)
        guard fileManager.fileExists(atPath: sourceURL.path) else {
            throw RadrootsAppleFileError.notFound("file not found")
        }
        return try stageFileURL(
            sourceURL,
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
    public func prepareExport(_ request: RadrootsExportDocumentRequest) throws -> RadrootsPreparedExportDocument {
        let preparedID = UUID().uuidString.lowercased()
        let directoryURL = preparedExportsRoot.appendingPathComponent(preparedID, isDirectory: true)
        let fileURL = directoryURL.appendingPathComponent(request.suggestedFilename).standardizedFileURL
        try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        switch request.source {
        case .inlineData(let data):
            try data.write(to: fileURL, options: [.atomic])
        case .file(let file):
            try copyReplacingItem(from: try roots.resolvedURL(for: file), to: fileURL)
        case .stagedBlob(let stagedBlob):
            try copyReplacingItem(from: try stagedBlobURL(for: stagedBlob), to: fileURL)
        }
        let sizeBytes: UInt64
        if let requestSizeBytes = request.sizeBytes {
            sizeBytes = requestSizeBytes
        } else {
            sizeBytes = try fileSizeUInt64(at: fileURL)
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
        let url = try stagedBlobURL(for: blob)
        guard fileManager.fileExists(atPath: url.path) else {
            throw RadrootsAppleFileError.notFound("staged blob not found")
        }
        let data = try Data(contentsOf: url)
        guard data.count == blob.sizeBytes else {
            throw RadrootsAppleFileError.permanentFailure("staged blob size does not match reference")
        }
        return data
    }

    public func releaseStagedBlob(_ blob: RadrootsStagedBlobReference) throws {
        let url = try stagedBlobURL(for: blob)
        if fileManager.fileExists(atPath: url.path) {
            try fileManager.removeItem(at: url)
        }
    }

    public func releasePreparedExport(_ preparedExport: RadrootsPreparedExportDocument) throws {
        let directoryURL = try preparedExportDirectoryURL(for: preparedExport)
        if fileManager.fileExists(atPath: directoryURL.path) {
            try fileManager.removeItem(at: directoryURL)
        }
    }

    @discardableResult
    public func sweepStagedBlobs(olderThan cutoff: Date) throws -> [RadrootsStagedBlobReference] {
        guard fileManager.fileExists(atPath: roots.stagedBlobsRoot.path) else {
            return []
        }
        let urls = try fileManager.contentsOfDirectory(
            at: roots.stagedBlobsRoot,
            includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey],
            options: []
        )
        var released: [RadrootsStagedBlobReference] = []
        for url in urls {
            let values = try url.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey])
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

    public func resetStagedBlobs() throws {
        if fileManager.fileExists(atPath: roots.stagedBlobsRoot.path) {
            try fileManager.removeItem(at: roots.stagedBlobsRoot)
        }
        try fileManager.createDirectory(at: roots.stagedBlobsRoot, withIntermediateDirectories: true)
    }

    public func resetFileRoots() throws {
        for scope in RadrootsFileScope.allCases {
            try reset(scope: scope)
        }
        try resetStagedBlobs()
    }

    private func stagedBlobURL(for blob: RadrootsStagedBlobReference) throws -> URL {
        let normalizedBlobID = try RadrootsStagedBlobReference.normalizedBlobID(blob.blobID)
        return roots.stagedBlobsRoot.appendingPathComponent(normalizedBlobID).standardizedFileURL
    }

    private var preparedExportsRoot: URL {
        roots.temporaryRoot.appendingPathComponent("prepared_exports", isDirectory: true).standardizedFileURL
    }

    private func preparedExportDirectoryURL(for preparedExport: RadrootsPreparedExportDocument) throws -> URL {
        let normalizedPreparedID = try RadrootsPreparedExportDocument.normalizedPreparedID(preparedExport.preparedID)
        let directoryURL = preparedExportsRoot.appendingPathComponent(normalizedPreparedID, isDirectory: true).standardizedFileURL
        guard preparedExport.fileURL.standardizedFileURL.path.hasPrefix(directoryURL.path + "/") else {
            throw RadrootsAppleFileError.invalidRequest("prepared export file escaped its directory")
        }
        return directoryURL
    }

    private func stageFileURL(
        _ sourceURL: URL,
        mediaType: String?,
        filenameHint: String?
    ) throws -> RadrootsStagedBlobReference {
        let sizeBytes = try fileSizeInt(at: sourceURL)
        let blobID = UUID().uuidString.lowercased()
        let blob = try RadrootsStagedBlobReference(
            blobID: blobID,
            sizeBytes: sizeBytes,
            mediaType: mediaType,
            filenameHint: filenameHint
        )
        let destinationURL = try stagedBlobURL(for: blob)
        try fileManager.createDirectory(at: roots.stagedBlobsRoot, withIntermediateDirectories: true)
        try copyReplacingItem(from: sourceURL, to: destinationURL)
        return blob
    }

    private func withSecurityScopedFile<T>(_ sourceURL: URL, _ body: (URL) throws -> T) throws -> T {
        guard sourceURL.isFileURL else {
            throw RadrootsAppleFileError.invalidRequest("external file url must be a file url")
        }
        let scopedURL = sourceURL.standardizedFileURL
        var isDirectory = ObjCBool(false)
        guard fileManager.fileExists(atPath: scopedURL.path, isDirectory: &isDirectory) else {
            throw RadrootsAppleFileError.notFound("external file not found")
        }
        guard !isDirectory.boolValue else {
            throw RadrootsAppleFileError.invalidRequest("external file url must reference a file")
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
            throw RadrootsAppleFileError.invalidRequest("copy source and destination must be file urls")
        }
        try createParentDirectory(for: destinationURL)
        if fileManager.fileExists(atPath: destinationURL.path) {
            try fileManager.removeItem(at: destinationURL)
        }
        try fileManager.copyItem(at: sourceURL, to: destinationURL)
    }

    private func createParentDirectory(for url: URL) throws {
        try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    }

    private func fileSize(at url: URL) throws -> Int {
        try fileSizeInt(at: url)
    }

    private func fileSizeInt(at url: URL) throws -> Int {
        let values = try url.resourceValues(forKeys: [.fileSizeKey])
        guard let size = values.fileSize else {
            throw RadrootsAppleFileError.permanentFailure("file size is unavailable")
        }
        return size
    }

    private func fileSizeUInt64(at url: URL) throws -> UInt64 {
        UInt64(try fileSizeInt(at: url))
    }

    private func relativePath(for url: URL, under rootURL: URL) throws -> String {
        let rootPath = rootURL.standardizedFileURL.path
        let filePath = url.standardizedFileURL.path
        guard filePath.hasPrefix(rootPath + "/") else {
            throw RadrootsAppleFileError.invalidRequest("file list entry escaped its scope")
        }
        return String(filePath.dropFirst(rootPath.count + 1))
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
            stagedBlobsRoot ?? normalizedTemporaryRoot.appendingPathComponent("staged_blobs", isDirectory: true),
            field: "stagedBlobsRoot"
        )
    }

    public static func appContainer(
        appIdentifier: String,
        fileManager: FileManager = .default
    ) throws -> Self {
        let normalizedAppIdentifier = try normalizedAppIdentifier(appIdentifier)
        let dataBaseURL = try fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let cacheBaseURL = try fileManager.url(
            for: .cachesDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let dataRoot = dataBaseURL.appendingPathComponent(normalizedAppIdentifier, isDirectory: true)
        let cacheRoot = cacheBaseURL.appendingPathComponent(normalizedAppIdentifier, isDirectory: true)
        let temporaryRoot = fileManager.temporaryDirectory
            .appendingPathComponent(normalizedAppIdentifier, isDirectory: true)
        return try Self(
            appIdentifier: normalizedAppIdentifier,
            dataRoot: dataRoot,
            cacheRoot: cacheRoot,
            temporaryRoot: temporaryRoot
        )
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
            throw RadrootsAppleFileError.invalidRequest("file relative path cannot be empty")
        }
        if NSString(string: trimmedPath).isAbsolutePath {
            throw RadrootsAppleFileError.invalidRequest("file relative path must not be absolute")
        }

        let candidateURL = rootURL.appendingPathComponent(trimmedPath).standardizedFileURL
        if candidateURL.path == rootURL.path {
            if allowRootDirectory {
                return candidateURL
            }
            throw RadrootsAppleFileError.invalidRequest("file relative path cannot resolve to its root")
        }
        guard candidateURL.path.hasPrefix(rootURL.path + "/") else {
            throw RadrootsAppleFileError.invalidRequest("file relative path must not escape its scope")
        }
        return candidateURL
    }

    public static func normalizedAppIdentifier(_ appIdentifier: String) throws -> String {
        let trimmed = appIdentifier.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw RadrootsAppleFileError.invalidRequest("app identifier cannot be empty")
        }
        return trimmed
    }

    public static func normalizedRootURL(_ rootURL: URL, field: String) throws -> URL {
        guard rootURL.isFileURL else {
            throw RadrootsAppleFileError.invalidRequest("\(field) must be a file URL")
        }
        let standardized = rootURL.standardizedFileURL
        guard standardized.path.hasPrefix("/") else {
            throw RadrootsAppleFileError.invalidRequest("\(field) must be absolute")
        }
        return standardized
    }
}
