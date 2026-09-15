import Foundation

public struct RadrootsAppleBackgroundTransferFileResolver: RadrootsBackgroundTransferFileResolver,
    Sendable {
    private let roots: RadrootsAppleFileRoots

    public init(roots: RadrootsAppleFileRoots) {
        self.roots = roots
    }

    public func prepareUploadLease(
        for request: RadrootsBackgroundTransferRequest, executionID: UUID,
        existing: RadrootsStagedBlobReference?
    ) throws -> RadrootsStagedBlobLease {
        guard case let .upload(source) = request.operation else { throw RadrootsBackgroundTransferError.invalidRequest }
        let owner = RadrootsAppleFileAccess(roots: roots)
        let identifier = executionID.uuidString.lowercased()
        if let existing {
            guard request.expectedSourceSHA256 == nil || request.expectedSourceSHA256 == existing.blobID else {
                throw RadrootsBackgroundTransferError.invalidRequest
            }
            return try owner.leaseStagedBlob(existing, expectedSHA256: existing.blobID, identifier: identifier)
        }
        let bytes = try read(source, maximumBytes: Int(request.maximumTransferBytes))
        let digest = RadrootsAppleFileDigest.sha256(bytes)
        guard request.expectedSourceSHA256 == nil || request.expectedSourceSHA256 == digest else {
            throw RadrootsBackgroundTransferError.invalidRequest
        }
        return try owner.leaseUploadBytes(bytes, identifier: identifier)
    }

    public func releaseUploadLease(executionID: UUID) throws {
        try RadrootsAppleFileAccess(roots: roots).releaseUploadLease(executionID: executionID)
    }

    public func resolve(_ file: RadrootsBackgroundTransferLocalFile) throws -> URL {
        let candidate: URL
        let root: URL
        switch file {
        case let .file(reference):
            candidate = try roots.resolvedURL(for: reference)
            root = roots.root(for: reference.scope)
        case let .stagedBlob(blob):
            candidate = try roots.stagedBlobURL(for: blob)
            root = roots.stagedBlobsRoot
        }
        let resolvedRoot = root.resolvingSymlinksInPath().standardizedFileURL
        let resolvedCandidate = candidate.resolvingSymlinksInPath().standardizedFileURL
        guard resolvedCandidate.path.hasPrefix(resolvedRoot.path + "/") else {
            throw RadrootsBackgroundTransferError.invalidRequest
        }
        return candidate
    }

    public func read(_ file: RadrootsBackgroundTransferLocalFile, maximumBytes: Int) throws -> Data {
        guard maximumBytes >= 0 else {
            throw RadrootsBackgroundTransferError.invalidRequest
        }
        let root: URL
        let relativePath: String
        let expectedBytes: Int?
        switch file {
        case let .file(reference):
            root = roots.root(for: reference.scope)
            relativePath = reference.relativePath
            expectedBytes = nil
        case let .stagedBlob(blob):
            root = roots.stagedBlobsRoot
            relativePath = blob.blobID
            expectedBytes = blob.sizeBytes
        }
        do {
            let data = try RadrootsGovernedFileReader.read(
                root: root,
                relativePath: relativePath,
                maximumBytes: maximumBytes
            )
            guard expectedBytes == nil || expectedBytes == data.count else {
                throw RadrootsBackgroundTransferError.invalidRequest
            }
            return data
        } catch let error as RadrootsBackgroundTransferError {
            throw error
        } catch {
            throw RadrootsBackgroundTransferError.invalidRequest
        }
    }
}
