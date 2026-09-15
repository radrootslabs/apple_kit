import Darwin
import Foundation

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
                )
            )
            let cacheBaseURL = try canonicalExistingDirectory(
                fileManager.url(
                    for: .cachesDirectory,
                    in: .userDomainMask,
                    appropriateFor: nil,
                    create: true
                )
            )
            let dataRoot = dataBaseURL.appendingPathComponent(normalizedAppIdentifier, isDirectory: true)
            let cacheRoot = cacheBaseURL.appendingPathComponent(
                normalizedAppIdentifier, isDirectory: true
            )
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
        let rootURL = root(for: file.scope)
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

        let components = try Self.normalizedRelativeComponents(trimmedPath)
        let candidateURL = components.isEmpty
            ? rootURL : rootURL.appendingPathComponent(components.joined(separator: "/"))
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

    private static func normalizedRelativeComponents(_ trimmedPath: String) throws -> [String] {
        var components: [String] = []
        for component in trimmedPath.split(separator: "/", omittingEmptySubsequences: true) {
            if component == "." {
                continue
            }
            if component == ".." {
                guard !components.isEmpty else { throw RadrootsAppleFileError.invalidRequest }
                components.removeLast()
            } else {
                guard !component.utf8.contains(0) else { throw RadrootsAppleFileError.invalidRequest }
                components.append(String(component))
            }
        }
        return components
    }

    public func stagedBlobURL(for blob: RadrootsStagedBlobReference) throws -> URL {
        let normalizedBlobID = try RadrootsStagedBlobReference.normalizedBlobID(blob.blobID)
        // Foundation standardization can rewrite an existing /private/var path
        // back to the /var symlink alias. Keep the already-admitted root bytes.
        return stagedBlobsRoot.appendingPathComponent(normalizedBlobID, isDirectory: false)
    }

    public static func normalizedAppIdentifier(_ appIdentifier: String) throws -> String {
        let trimmed = appIdentifier.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw RadrootsAppleFileError.invalidRequest
        }
        return trimmed
    }

    public static func normalizedRootURL(_ rootURL: URL, field _: String) throws -> URL {
        guard rootURL.isFileURL else {
            throw RadrootsAppleFileError.invalidRequest
        }
        guard rootURL.path.hasPrefix("/"), !rootURL.path.utf8.contains(0) else {
            throw RadrootsAppleFileError.invalidRequest
        }
        var components: [String] = []
        for component in rootURL.path.split(separator: "/", omittingEmptySubsequences: true) {
            if component == "." {
                continue
            }
            if component == ".." {
                if !components.isEmpty {
                    components.removeLast()
                }
            } else {
                components.append(String(component))
            }
        }
        return URL(fileURLWithPath: "/" + components.joined(separator: "/"), isDirectory: true)
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
