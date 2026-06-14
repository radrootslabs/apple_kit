import Foundation
import Testing
@testable import RadrootsKit

@Test func appleFileAccessWritesReadsListsAndDeletesInlineFiles() throws {
    let access = try testFileAccess()
    let file = RadrootsFileReference(scope: .data, relativePath: "identity/public.json")
    let data = Data(#"{"npub":"npub1test"}"#.utf8)

    try access.write(.inline(data), to: file)

    #expect(try access.read(file, mode: .inline) == .inline(data))
    let entries = try access.list(RadrootsFileReference(scope: .data, relativePath: "identity"))
    #expect(entries.map(\.file.relativePath) == ["identity/public.json"])
    #expect(entries.first?.name == "public.json")
    #expect(entries.first?.sizeBytes == data.count)

    try access.delete(file)
    try access.delete(file)
    #expect(try access.list(RadrootsFileReference(scope: .data, relativePath: "identity")).isEmpty)
}

@Test func appleFileAccessWritesFilesFromStagedBlobsAndReleasesThem() throws {
    let access = try testFileAccess()
    let data = Data("hello staged blob".utf8)
    let staged = try access.stageBlob(data, mediaType: "text/plain", filenameHint: "note.txt")
    let file = RadrootsFileReference(scope: .cache, relativePath: "outbox/note.txt")

    #expect(try access.readStagedBlob(staged) == data)

    try access.write(.stagedBlob(staged), to: file)
    try access.releaseStagedBlob(staged)

    #expect(try access.read(file, mode: .inline) == .inline(data))
    #expect(throws: RadrootsAppleFileError.self) {
        _ = try access.readStagedBlob(staged)
    }
}

@Test func appleFileAccessStagesLargeReadsWhenInlineLimitIsExceeded() throws {
    let access = try testFileAccess()
    let file = RadrootsFileReference(scope: .data, relativePath: "events/large.json")
    let data = Data("large payload".utf8)

    try access.write(.inline(data), to: file)

    guard case .stagedBlob(let staged) = try access.read(file, mode: .preferInline(maxBytes: 4)) else {
        Issue.record("expected staged blob result")
        return
    }

    #expect(staged.filenameHint == "large.json")
    #expect(try access.readStagedBlob(staged) == data)
}

@Test func appleFileAccessKeepsSmallReadsInlineWhenLimitAllowsIt() throws {
    let access = try testFileAccess()
    let file = RadrootsFileReference(scope: .logs, relativePath: "radroots.log")
    let data = Data("log".utf8)

    try access.write(.inline(data), to: file)

    #expect(try access.read(file, mode: .preferInline(maxBytes: data.count)) == .inline(data))
}

@Test func appleFileAccessRejectsInvalidStagedBlobMetadata() throws {
    let access = try testFileAccess()

    #expect(throws: RadrootsAppleFileError.self) {
        _ = try RadrootsStagedBlobReference(blobID: "../escape", sizeBytes: 1)
    }
    #expect(throws: RadrootsAppleFileError.self) {
        _ = try access.stageBlob(Data("bad".utf8), mediaType: "text/plain", filenameHint: "../secret.txt")
    }
    #expect(throws: RadrootsAppleFileError.self) {
        _ = try access.read(RadrootsFileReference(scope: .data, relativePath: "missing.json"), mode: .inline)
    }
}

@Test func appleFileAccessSweepsOnlyExpiredStagedBlobs() throws {
    let access = try testFileAccess()
    let oldBlob = try access.stageBlob(Data("old".utf8), mediaType: nil, filenameHint: nil)
    let newBlob = try access.stageBlob(Data("new".utf8), mediaType: nil, filenameHint: nil)
    let oldURL = access.roots.stagedBlobsRoot.appendingPathComponent(oldBlob.blobID)
    let oldDate = Date(timeIntervalSince1970: 10)
    let cutoff = Date(timeIntervalSince1970: 20)

    try FileManager.default.setAttributes([.modificationDate: oldDate], ofItemAtPath: oldURL.path)

    let swept = try access.sweepStagedBlobs(olderThan: cutoff)

    #expect(swept.map(\.blobID) == [oldBlob.blobID])
    #expect(throws: RadrootsAppleFileError.self) {
        _ = try access.readStagedBlob(oldBlob)
    }
    #expect(try access.readStagedBlob(newBlob) == Data("new".utf8))
}

@Test func appleFileAccessResetsFileRootsAndStagedBlobs() throws {
    let access = try testFileAccess()
    let dataFile = RadrootsFileReference(scope: .data, relativePath: "state.json")
    let cacheFile = RadrootsFileReference(scope: .cache, relativePath: "cache.json")
    let staged = try access.stageBlob(Data("blob".utf8), mediaType: nil, filenameHint: nil)

    try access.write(.inline(Data("data".utf8)), to: dataFile)
    try access.write(.inline(Data("cache".utf8)), to: cacheFile)

    try access.reset(scope: .data)

    #expect(try access.list(RadrootsFileReference(scope: .data, relativePath: "")).isEmpty)
    #expect(try access.read(cacheFile, mode: .inline) == .inline(Data("cache".utf8)))

    try access.resetStagedBlobs()

    #expect(throws: RadrootsAppleFileError.self) {
        _ = try access.readStagedBlob(staged)
    }
}

private func testFileAccess() throws -> RadrootsAppleFileAccess {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("radroots-file-access-\(UUID().uuidString)", isDirectory: true)
    let roots = try RadrootsAppleFileRoots(
        appIdentifier: "org.radroots.tests",
        dataRoot: root.appendingPathComponent("data", isDirectory: true),
        cacheRoot: root.appendingPathComponent("cache", isDirectory: true),
        temporaryRoot: root.appendingPathComponent("tmp", isDirectory: true)
    )
    return RadrootsAppleFileAccess(roots: roots)
}
