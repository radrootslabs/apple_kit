import Darwin
import Foundation
@testable import RadrootsKit
import Testing

@Test func durableStagingPreservesOldBytesAtEveryInterruptedInstallBoundary() throws {
    for phase in RadrootsAtomicFile.Phase.allCases {
        let fixture = try DurableStagingFixture()
        defer { fixture.remove() }
        let url = fixture.base.appendingPathComponent("owned/value")
        let old = Data("old valid object".utf8)
        let new = Data(repeating: 42, count: 100_000)
        try RadrootsAtomicFile.install(old, at: url)
        #expect(throws: StagingFault.self) {
            try RadrootsAtomicFile.installForTesting(new, at: url) { current in
                if current == phase {
                    throw StagingFault.interrupted
                }
            }
        }
        #expect(try Data(contentsOf: url) == (phase == .beforeDirectorySync ? new : old))
        try RadrootsAtomicFile.install(new, at: url)
        #expect(try Data(contentsOf: url) == new)
        #expect(try FileManager.default.contentsOfDirectory(atPath: url.deletingLastPathComponent().path) == ["value"])
    }
}

@Test func durableStagingRejectsSymlinkAndReplacedDirectoryAuthority() throws {
    let fixture = try DurableStagingFixture()
    defer { fixture.remove() }
    let outside = fixture.base.appendingPathComponent("outside")
    let owned = fixture.base.appendingPathComponent("owned")
    try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
    let external = outside.appendingPathComponent("value")
    try Data("outside".utf8).write(to: external)
    try FileManager.default.createSymbolicLink(at: owned, withDestinationURL: outside)
    #expect(throws: RadrootsAppleFileError.self) {
        try RadrootsAtomicFile.install(Data("bad".utf8), at: owned.appendingPathComponent("value"))
    }
    #expect(try Data(contentsOf: external) == Data("outside".utf8))
    try FileManager.default.removeItem(at: owned)
    let url = owned.appendingPathComponent("value")
    try RadrootsAtomicFile.install(Data("old".utf8), at: url)
    let retained = fixture.base.appendingPathComponent("retained")
    #expect(throws: RadrootsAppleFileError.self) {
        try RadrootsAtomicFile.installForTesting(Data("new".utf8), at: url) { phase in
            if phase == .beforeInstall {
                try FileManager.default.moveItem(at: owned, to: retained)
                try FileManager.default.createSymbolicLink(at: owned, withDestinationURL: outside)
            }
        }
    }
    #expect(try Data(contentsOf: external) == Data("outside".utf8))
    #expect(try Data(contentsOf: retained.appendingPathComponent("value")) == Data("old".utf8))
}

@Test func durableStagingPreservesOldFileWhenDestinationCannotBeWritten() throws {
    let fixture = try DurableStagingFixture()
    defer { fixture.remove() }
    let directory = fixture.base.appendingPathComponent("locked")
    let url = directory.appendingPathComponent("value")
    try RadrootsAtomicFile.install(Data("old".utf8), at: url)
    #expect(Darwin.chmod(directory.path, 0o500) == 0)
    defer { _ = Darwin.chmod(directory.path, 0o700) }
    #expect(throws: RadrootsAppleFileError.self) {
        try RadrootsAtomicFile.install(Data("replacement".utf8), at: url)
    }
    #expect(try Data(contentsOf: url) == Data("old".utf8))
}

@Test func durableStagingSurvivesCachePurgeAndRejectsOpaqueIdentityConflicts() throws {
    let fixture = try DurableStagingFixture()
    defer { fixture.remove() }
    let access = RadrootsAppleFileAccess(roots: fixture.roots)
    let bytes = Data("saved referenced draft".utf8)
    let blob = try access.stageBlob(bytes)
    try access.reset(scope: .cache)
    try access.reset(scope: .temporary)
    #expect(try access.readStagedBlob(blob) == bytes)
    #expect(try fixture.roots.stagedBlobURL(for: blob).path.hasPrefix(fixture.roots.stagedBlobsRoot.path + "/"))
    try RadrootsAtomicFile.synchronizeExisting(at: fixture.roots.stagedBlobURL(for: blob))
    try access.installStagedBlob(bytes, reference: blob)
    #expect(throws: RadrootsAppleFileError.self) {
        try access.installStagedBlob(Data(repeating: 65, count: bytes.count), reference: blob)
    }
    #expect(try access.readStagedBlob(blob) == bytes)
    let partial = fixture.roots.stagedBlobsRoot.appendingPathComponent(".radroots_pending_interrupted")
    try Data("partial".utf8).write(to: partial)
    _ = try access.sweepStagedBlobs(olderThan: .distantPast)
    #expect(FileManager.default.fileExists(atPath: partial.path))
    #expect(try access.readStagedBlob(blob) == bytes)
}

@Test func durableStagingRepairsOnlyVerifiedContentIdentityAndPreservesSourceOnCopyFailure() throws {
    let fixture = try DurableStagingFixture()
    defer { fixture.remove() }
    let access = RadrootsAppleFileAccess(roots: fixture.roots)
    let bytes = Data("verified bytes".utf8)
    let blob = try RadrootsStagedBlobReference(blobID: RadrootsAppleFileDigest.sha256(bytes), sizeBytes: bytes.count)
    try access.installStagedBlob(bytes, reference: blob)
    let url = try fixture.roots.stagedBlobURL(for: blob)
    try Data("corrupt".utf8).write(to: url, options: .atomic)
    try access.installStagedBlob(bytes, reference: blob)
    #expect(try access.readStagedBlob(blob) == bytes)
    let destination = RadrootsFileReference(scope: .data, relativePath: "imported")
    try access.write(.inline(bytes), to: destination)
    let invalid = fixture.base.appendingPathComponent("missing")
    #expect(throws: RadrootsAppleFileError.self) {
        _ = try access.copyExternalFile(invalid, to: destination, mediaType: nil, suggestedFilename: nil)
    }
    #expect(try access.read(destination, mode: .inline(maxBytes: bytes.count)) == .inline(bytes))
}

@Test func stagedBlobLeaseKeepsExactBytesAfterSourceReplacementPurgeAndRestart() throws {
    let fixture = try DurableStagingFixture()
    defer { fixture.remove() }
    let access = RadrootsAppleFileAccess(roots: fixture.roots)
    let bytes = Data("original upload body".utf8)
    let blob = try access.stageBlob(bytes)
    let digest = RadrootsAppleFileDigest.sha256(bytes)
    let lease = try access.leaseStagedBlob(blob, expectedSHA256: digest, identifier: "stable_attempt")
    let source = try fixture.roots.stagedBlobURL(for: blob)
    try Data(repeating: 65, count: bytes.count).write(to: source, options: .atomic)
    try access.releaseStagedBlob(blob)
    try access.resetStagedBlobs()
    try access.reset(scope: .cache)
    try access.reset(scope: .temporary)
    #expect(try Data(contentsOf: lease.fileURL) == bytes)
    let recoveredRoots = try RadrootsAppleFileRoots(
        appIdentifier: "org.radroots.tests", dataRoot: fixture.roots.dataRoot,
        cacheRoot: fixture.roots.cacheRoot, temporaryRoot: fixture.roots.temporaryRoot,
        stagedBlobsRoot: fixture.roots.stagedBlobsRoot
    )
    #expect(recoveredRoots.dataRoot.path == fixture.roots.dataRoot.path)
    let reopened = RadrootsAppleFileAccess(roots: recoveredRoots)
    #expect(try reopened.leaseStagedBlob(blob, expectedSHA256: digest, identifier: "stable_attempt") == lease)
    let attributes = try FileManager.default.attributesOfItem(atPath: lease.fileURL.path)
    #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o400)
    #expect(!lease.debugDescription.contains(fixture.base.path))
    try reopened.releaseStagedBlobLease(lease)
    try reopened.releaseStagedBlobLease(lease)
    #expect(!FileManager.default.fileExists(atPath: lease.fileURL.path))
}

@Test func stagedBlobLeaseRejectsChangedBytesAndUnsafeIdentifiers() throws {
    let fixture = try DurableStagingFixture()
    defer { fixture.remove() }
    let access = RadrootsAppleFileAccess(roots: fixture.roots)
    let bytes = Data("original body".utf8)
    let blob = try access.stageBlob(bytes)
    let digest = RadrootsAppleFileDigest.sha256(bytes)
    for identifier in ["../escape", "bad/child", " ", String(repeating: "x", count: 129)] {
        #expect(throws: RadrootsAppleFileError.self) {
            _ = try access.leaseStagedBlob(blob, expectedSHA256: digest, identifier: identifier)
        }
    }
    let lease = try access.leaseStagedBlob(blob, expectedSHA256: digest, identifier: "attempt")
    try Data(repeating: 65, count: bytes.count).write(to: lease.fileURL, options: .atomic)
    #expect(throws: RadrootsAppleFileError.self) {
        _ = try access.leaseStagedBlob(blob, expectedSHA256: digest, identifier: "attempt")
    }
    #expect(try Data(contentsOf: lease.fileURL) != bytes)
}

@Test func stagedBlobLeaseConcurrentSameIdentityHasOneImmutableFile() async throws {
    let fixture = try DurableStagingFixture()
    defer { fixture.remove() }
    let roots = fixture.roots
    let bytes = Data(repeating: 7, count: 100_000)
    let blob = try RadrootsAppleFileAccess(roots: roots).stageBlob(bytes)
    let digest = RadrootsAppleFileDigest.sha256(bytes)
    let leases = try await withThrowingTaskGroup(of: RadrootsStagedBlobLease.self) { group in
        for _ in 0 ..< 8 {
            group.addTask {
                try RadrootsAppleFileAccess(roots: roots).leaseStagedBlob(
                    blob,
                    expectedSHA256: digest,
                    identifier: "same"
                )
            }
        }
        var results: [RadrootsStagedBlobLease] = []
        for try await result in group {
            results.append(result)
        }
        return results
    }
    #expect(leases.count == 8)
    let first = try #require(leases.first)
    #expect(leases.allSatisfy { $0 == first })
    #expect(try Data(contentsOf: first.fileURL) == bytes)
    #expect(try FileManager.default
        .contentsOfDirectory(atPath: first.fileURL.deletingLastPathComponent().path) == ["same"])
}

private enum StagingFault: Error { case interrupted }

private struct DurableStagingFixture {
    let base: URL
    let roots: RadrootsAppleFileRoots

    init() throws {
        let raw = FileManager.default.temporaryDirectory
            .appendingPathComponent("radroots-durable-staging-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: raw, withIntermediateDirectories: true)
        let pointer = try #require(raw.path.withCString { Darwin.realpath($0, nil) })
        defer { Darwin.free(pointer) }
        base = URL(fileURLWithPath: String(cString: pointer), isDirectory: true)
        let data = base.appendingPathComponent("data", isDirectory: true)
        roots = try RadrootsAppleFileRoots(appIdentifier: "org.radroots.tests", dataRoot: data,
                                           cacheRoot: base.appendingPathComponent("cache", isDirectory: true),
                                           temporaryRoot: base.appendingPathComponent("tmp", isDirectory: true),
                                           stagedBlobsRoot: data.appendingPathComponent(
                                               "staged_blobs",
                                               isDirectory: true
                                           ))
    }

    func remove() {
        try? FileManager.default.removeItem(at: base)
    }
}
