import Darwin
import Foundation
@testable import RadrootsKit
import Testing

@Test func fileCapacityClassificationIsBoundedTypedAndRedacted() throws {
    for code in [ENOSPC, EDQUOT] {
        let raw = NSError(domain: NSPOSIXErrorDomain, code: Int(code), userInfo: [NSFilePathErrorKey: "/private/value"])
        #expect(RadrootsAppleFileError.posix(code) == .spaceInsufficient)
        #expect(RadrootsAppleFileError.classified(raw) == .spaceInsufficient)
        let wrapped = NSError(domain: NSCocoaErrorDomain, code: CocoaError.Code.fileWriteUnknown.rawValue,
                              userInfo: [NSUnderlyingErrorKey: raw])
        #expect(RadrootsAppleFileError.classified(wrapped) == .spaceInsufficient)
        #expect(RadrootsBackgroundTransferError.persistence(wrapped) == .spaceInsufficient)
    }
    #expect(RadrootsAppleFileError.classified(CocoaError(.fileWriteOutOfSpace)) == .spaceInsufficient)
    #expect(RadrootsAppleFileError.classified(RadrootsAppleFileError.notFound) == .notFound)
    #expect(RadrootsAppleFileError.posix(EIO) == .permanentFailure)
    #expect(RadrootsAppleFileError.classified(NSError(domain: "unrelated", code: Int(ENOSPC))) == .permanentFailure)
    var nested = NSError(domain: NSPOSIXErrorDomain, code: Int(ENOSPC))
    for _ in 0 ..< 8 { nested = NSError(domain: "wrapper", code: 0, userInfo: [NSUnderlyingErrorKey: nested]) }
    #expect(RadrootsAppleFileError.classified(nested) == .permanentFailure)
    #expect(RadrootsAppleFileError.spaceInsufficient.errorDescription == "There is not enough storage space to complete the file operation.")
    #expect(String(describing: RadrootsAppleFileError.spaceInsufficient) == "spaceInsufficient")
    #expect(RadrootsAppleMediaPicker.adapt(fileError: .spaceInsufficient) == .spaceInsufficient)
    #expect(RadrootsAppleMediaPicker.adapt(error: RadrootsAppleFileError.spaceInsufficient) == .spaceInsufficient)
    #expect(RadrootsCaptureIntakeError.spaceInsufficient.errorDescription == "There is not enough storage space to save the capture.")
    #expect(RadrootsBackgroundTransferError.persistence(.receiptCapacityExceeded as RadrootsBackgroundTransferError) == .receiptCapacityExceeded)
    #expect(RadrootsBackgroundTransferError.persistence(RadrootsBackgroundTransferError.invalidRequest) == .persistenceFailure)
}

@Test func fileCapacityReachesActualFoundationAndLockCallers() throws {
    let fixture = try CapacityFixture()
    defer { fixture.remove() }
    let access = RadrootsAppleFileAccess(roots: fixture.roots)
    #expect(throws: RadrootsAppleFileError.spaceInsufficient) {
        try access.classifiedFileSystemOperation {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(ENOSPC))
        }
    }
    for code in [ENOSPC, EDQUOT] {
        #expect(throws: RadrootsAppleFileError.spaceInsufficient) {
            _ = try RadrootsAtomicFile.acquireExclusiveLock(at: fixture.base.appendingPathComponent("lock"),
                                                            injectedOpenError: { _ in code })
        }
    }
    #expect(!FileManager.default.fileExists(atPath: fixture.base.appendingPathComponent("lock").path))
    let directory = fixture.base.appendingPathComponent("directory")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
    errno = ENOSPC
    #expect(throws: RadrootsAppleFileError.permanentFailure) {
        try RadrootsAtomicFile.synchronizeExisting(at: directory)
    }
}

@Test func fileCapacityPreservesOldOrAmbiguousBytesAtEveryInstallBoundary() throws {
    for phase in RadrootsAtomicFile.Phase.allCases {
        let fixture = try CapacityFixture()
        defer { fixture.remove() }
        let url = fixture.base.appendingPathComponent("value")
        let old = Data("acknowledged".utf8), pending = Data(repeating: 42, count: 100_000)
        try RadrootsAtomicFile.install(old, at: url)
        #expect(throws: RadrootsAppleFileError.spaceInsufficient) {
            try RadrootsAtomicFile.installForTesting(pending, at: url) { current in
                if current == phase { throw RadrootsAppleFileError.posix(ENOSPC) }
            }
        }
        #expect(try Data(contentsOf: url) == (phase == .beforeDirectorySync ? pending : old))
        try RadrootsAtomicFile.install(pending, at: url)
        #expect(try Data(contentsOf: url) == pending)
    }
}

@Test func fileCapacityPreservesOriginalFailureAndSourceWhenLeaseIsAbsent() throws {
    let fixture = try CapacityFixture()
    defer { fixture.remove() }
    let live = RadrootsAppleFileAccess(roots: fixture.roots)
    let bytes = Data("pending upload".utf8), digest = RadrootsAppleFileDigest.sha256(bytes)
    let blob = try live.stageBlob(bytes)
    let access = RadrootsAppleFileAccess(roots: fixture.roots, persistence: capacityPersistence(.beforeInstall))
    #expect(throws: RadrootsAppleFileError.spaceInsufficient) {
        _ = try access.leaseStagedBlob(blob, expectedSHA256: digest, identifier: "pending")
    }
    #expect(throws: RadrootsAppleFileError.spaceInsufficient) {
        _ = try access.leaseUploadBytes(bytes, identifier: "upload")
    }
    #expect(try live.readStagedBlob(blob) == bytes)
    let lease = try live.leaseStagedBlob(blob, expectedSHA256: digest, identifier: "pending")
    #expect(try Data(contentsOf: lease.fileURL) == bytes)
    let prior = try live.leaseUploadBytes(Data("other".utf8), identifier: "conflict")
    #expect(throws: RadrootsAppleFileError.permanentFailure) {
        _ = try access.leaseUploadBytes(bytes, identifier: "conflict")
    }
    #expect(try Data(contentsOf: prior.fileURL) == Data("other".utf8))
}

@Test func fileCapacityDoesNotSwallowMatchingStagedBlobOrLeaseSyncFailure() throws {
    let fixture = try CapacityFixture()
    defer { fixture.remove() }
    let bytes = Data("same exact bytes".utf8), digest = RadrootsAppleFileDigest.sha256(bytes)
    let blob = try RadrootsStagedBlobReference(blobID: "opaque", sizeBytes: bytes.count)
    let faulted = RadrootsAppleFileAccess(roots: fixture.roots,
                                        persistence: capacityPersistence(.beforeDirectorySync, failSync: true))
    #expect(throws: RadrootsAppleFileError.spaceInsufficient) { try faulted.installStagedBlob(bytes, reference: blob) }
    let live = RadrootsAppleFileAccess(roots: fixture.roots)
    #expect(try live.readStagedBlob(blob) == bytes)
    #expect(throws: RadrootsAppleFileError.spaceInsufficient) { try faulted.installStagedBlob(bytes, reference: blob) }
    #expect(throws: RadrootsAppleFileError.spaceInsufficient) {
        _ = try faulted.leaseStagedBlob(blob, expectedSHA256: digest, identifier: "ambiguous")
    }
    #expect(throws: RadrootsAppleFileError.spaceInsufficient) {
        _ = try faulted.leaseUploadBytes(bytes, identifier: "ambiguous_upload")
    }
    let lease = try live.leaseStagedBlob(blob, expectedSHA256: digest, identifier: "ambiguous")
    #expect(try Data(contentsOf: lease.fileURL) == bytes)
    #expect(throws: RadrootsAppleFileError.spaceInsufficient) {
        _ = try faulted.leaseStagedBlob(blob, expectedSHA256: digest, identifier: "ambiguous")
    }
    try live.installStagedBlob(bytes, reference: blob)
    let recovered = RadrootsAppleFileAccess(roots: fixture.roots, persistence: capacityPersistence(.beforeDirectorySync))
    let exact = try recovered.leaseStagedBlob(blob, expectedSHA256: digest, identifier: "reflushed")
    #expect(try Data(contentsOf: exact.fileURL) == bytes)
    let attributes = try FileManager.default.attributesOfItem(atPath: exact.fileURL.path)
    #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o400)
}

func capacityPersistence(_ phase: RadrootsAtomicFile.Phase, failSync: Bool = false) -> RadrootsFilePersistence {
    RadrootsFilePersistence(install: { bytes, url, mode, readOnly in
        try RadrootsAtomicFile.installForTesting(bytes, at: url, mode: mode, readOnly: readOnly) { current in
            if current == phase { throw RadrootsAppleFileError.posix(ENOSPC) }
        }
    }, synchronize: { url in
        if failSync { throw RadrootsAppleFileError.posix(EDQUOT) }
        try RadrootsAtomicFile.synchronizeExisting(at: url)
    })
}

struct CapacityFixture {
    let roots: RadrootsAppleFileRoots
    var base: URL { roots.dataRoot.deletingLastPathComponent() }
    init() throws { roots = try appleTransferRoots() }
    func remove() { try? FileManager.default.removeItem(at: base) }
}
