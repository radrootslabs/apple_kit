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
