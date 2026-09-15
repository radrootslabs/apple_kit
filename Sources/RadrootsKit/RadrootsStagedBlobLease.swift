import Foundation

/// An owner-managed immutable copy. Keep it until the native consumer is
/// definitively finished; releasing the original staged blob cannot remove it.
/// A full explicit data-root reset still removes all owned application state.
public struct RadrootsStagedBlobLease: Sendable, Equatable, CustomDebugStringConvertible {
    public let identifier: String
    public let blob: RadrootsStagedBlobReference
    public let sha256: String
    public let fileURL: URL

    fileprivate init(identifier: String, blob: RadrootsStagedBlobReference, sha256: String, fileURL: URL) {
        self.identifier = identifier
        self.blob = blob
        self.sha256 = sha256
        self.fileURL = fileURL
    }

    public var debugDescription: String {
        "RadrootsStagedBlobLease(identifier: \(identifier), sha256: \(sha256), sizeBytes: \(blob.sizeBytes))"
    }
}

extension RadrootsAppleFileAccess {
    func leaseUploadBytes(_ bytes: Data, identifier: String) throws -> RadrootsStagedBlobLease {
        let digest = RadrootsAppleFileDigest.sha256(bytes)
        let blob = try RadrootsStagedBlobReference(blobID: digest, sizeBytes: bytes.count)
        let url = try leaseURL(identifier)
        let lease = RadrootsStagedBlobLease(identifier: identifier, blob: blob, sha256: digest, fileURL: url)
        do {
            try RadrootsAtomicFile.install(bytes, at: url, mode: .create, readOnly: true)
        } catch {
            try validateLease(lease)
            try RadrootsAtomicFile.synchronizeExisting(at: url)
        }
        try validateLease(lease)
        return lease
    }

    func releaseUploadLease(executionID: UUID) throws {
        try RadrootsAtomicFile.remove(at: leaseURL(executionID.uuidString.lowercased()))
    }

    /// Installs an exact reference without removing a prior file first. Matching
    /// installs are idempotent. An opaque ID cannot replace different bytes;
    /// a SHA256 ID can repair corrupted bytes only with its verified preimage.
    public func installStagedBlob(_ data: Data, reference: RadrootsStagedBlobReference) throws {
        try Self.validateStagedReference(reference)
        guard data.count == reference.sizeBytes else { throw RadrootsAppleFileError.invalidRequest }
        let url = try roots.stagedBlobURL(for: reference)
        do {
            try RadrootsAtomicFile.install(data, at: url, mode: .create)
        } catch {
            let originalError = error
            do {
                let existing = try readStagedBlob(reference)
                if existing == data {
                    try RadrootsAtomicFile.synchronizeExisting(at: url)
                    return
                }
            } catch RadrootsAppleFileError.notFound {
                throw originalError
            } catch {
                // Corrupt size/bytes may be repaired only by the exact content
                // identity below. Symlink traversal still fails in the writer.
            }
            guard RadrootsAppleFileDigest.sha256(data) == reference.blobID else {
                throw RadrootsAppleFileError.permanentFailure
            }
            try RadrootsAtomicFile.install(data, at: url)
        }
    }

    /// Reuses the same immutable lease on retry, even after the source blob is
    /// gone. The host persists the identifier with its native operation before
    /// admission; this generic owner does not invent transfer/domain identity.
    public func leaseStagedBlob(
        _ blob: RadrootsStagedBlobReference, expectedSHA256: String,
        identifier: String = UUID().uuidString.lowercased()
    ) throws -> RadrootsStagedBlobLease {
        try Self.validateStagedReference(blob)
        guard expectedSHA256.range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil else {
            throw RadrootsAppleFileError.invalidRequest
        }
        let url = try leaseURL(identifier)
        let lease = RadrootsStagedBlobLease(identifier: identifier, blob: blob, sha256: expectedSHA256, fileURL: url)
        do {
            try validateLease(lease)
            try RadrootsAtomicFile.synchronizeExisting(at: url)
            return lease
        } catch RadrootsAppleFileError.notFound {
            // Only definitive absence admits creation; protected/corrupt or
            // substituted existing leases must never be overwritten.
        }
        let bytes = try readStagedBlob(blob)
        guard RadrootsAppleFileDigest.sha256(bytes) == expectedSHA256 else {
            throw RadrootsAppleFileError.permanentFailure
        }
        do {
            try RadrootsAtomicFile.install(bytes, at: url, mode: .create, readOnly: true)
        } catch {
            // A competing identical admission or an ambiguous directory sync
            // can be recovered only by checking and flushing the exact lease.
            try validateLease(lease)
            try RadrootsAtomicFile.synchronizeExisting(at: url)
        }
        try validateLease(lease)
        return lease
    }

    public func releaseStagedBlobLease(_ lease: RadrootsStagedBlobLease) throws {
        guard try leaseURL(lease.identifier) == lease.fileURL else { throw RadrootsAppleFileError.invalidRequest }
        do {
            try validateLease(lease)
        } catch RadrootsAppleFileError.notFound {
            return
        }
        try RadrootsAtomicFile.remove(at: lease.fileURL)
    }

    private func leaseURL(_ identifier: String) throws -> URL {
        guard identifier.utf8.count <= 128,
              try RadrootsStagedBlobReference.normalizedBlobID(identifier) == identifier
        else { throw RadrootsAppleFileError.invalidRequest }
        return roots.dataRoot.appendingPathComponent("staged_blob_leases", isDirectory: true)
            .appendingPathComponent(identifier)
    }

    private func validateLease(_ lease: RadrootsStagedBlobLease) throws {
        let bytes: Data
        do {
            bytes = try RadrootsGovernedFileReader.read(
                root: lease.fileURL.deletingLastPathComponent(), relativePath: lease.identifier,
                maximumBytes: lease.blob.sizeBytes
            )
        } catch RadrootsGovernedFileReadError.unavailable {
            throw RadrootsAppleFileError.notFound
        } catch {
            throw RadrootsAppleFileError.permanentFailure
        }
        guard bytes.count == lease.blob.sizeBytes, RadrootsAppleFileDigest.sha256(bytes) == lease.sha256 else {
            throw RadrootsAppleFileError.permanentFailure
        }
    }

    private static func validateStagedReference(_ blob: RadrootsStagedBlobReference) throws {
        guard (0 ... RadrootsAtomicFile.maximumBytes).contains(blob.sizeBytes),
              try RadrootsStagedBlobReference(blobID: blob.blobID, sizeBytes: blob.sizeBytes,
                                              mediaType: blob.mediaType, filenameHint: blob.filenameHint) == blob
        else { throw RadrootsAppleFileError.invalidRequest }
    }
}
