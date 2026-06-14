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

@Test func appleFileAccessStagesScopedFilesWithoutChangingTheSource() throws {
    let access = try testFileAccess()
    let file = RadrootsFileReference(scope: .data, relativePath: "events/large.json")
    let data = Data(repeating: 7, count: 1_048_576)

    try access.write(.inline(data), to: file)
    let staged = try access.stageFile(file, mediaType: "application/json", filenameHint: "large.json")

    try access.delete(file)

    #expect(staged.mediaType == "application/json")
    #expect(staged.filenameHint == "large.json")
    #expect(staged.sizeBytes == data.count)
    #expect(try access.readStagedBlob(staged) == data)
}

@Test func appleFileAccessStagesExternalFiles() throws {
    let access = try testFileAccess()
    let externalURL = try writeExternalTestFile(name: "selected.txt", data: Data("external".utf8))

    let staged = try access.stageExternalFile(externalURL, mediaType: "text/plain", filenameHint: nil)

    #expect(staged.mediaType == "text/plain")
    #expect(staged.filenameHint == "selected.txt")
    #expect(try access.readStagedBlob(staged) == Data("external".utf8))
}

@Test func appleFileAccessCopiesExternalFilesIntoScopedStorage() throws {
    let access = try testFileAccess()
    let externalURL = try writeExternalTestFile(name: "relays.json", data: Data(#"{"relays":[]}"#.utf8))
    let destination = RadrootsFileReference(scope: .data, relativePath: "imports/relays.json")

    let imported = try access.copyExternalFile(
        externalURL,
        to: destination,
        mediaType: "application/json",
        suggestedFilename: nil
    )

    #expect(imported.file == destination)
    #expect(imported.originalURL == externalURL.standardizedFileURL)
    #expect(imported.suggestedFilename == "relays.json")
    #expect(imported.mediaType == "application/json")
    #expect(imported.sizeBytes == UInt64(Data(#"{"relays":[]}"#.utf8).count))
    #expect(try access.read(destination, mode: .inline) == .inline(Data(#"{"relays":[]}"#.utf8)))
}

@Test func appleFileAccessPreparesAndReleasesExportDocuments() throws {
    let access = try testFileAccess()
    let file = RadrootsFileReference(scope: .data, relativePath: "exports/diagnostics.json")
    let data = Data(#"{"status":"ok"}"#.utf8)
    try access.write(.inline(data), to: file)
    let staged = try access.stageFile(file, mediaType: "application/json", filenameHint: "diagnostics.json")

    let filePrepared = try access.prepareExport(
        try RadrootsExportDocumentRequest(
            source: .file(file),
            suggestedFilename: "diagnostics.json",
            mediaType: "application/json"
        )
    )
    let stagedPrepared = try access.prepareExport(
        try RadrootsExportDocumentRequest(
            source: .stagedBlob(staged),
            suggestedFilename: "staged-diagnostics.json",
            mediaType: "application/json"
        )
    )
    let inlinePrepared = try access.prepareExport(
        try RadrootsExportDocumentRequest(
            source: .inlineData(data),
            suggestedFilename: "inline-diagnostics.json",
            mediaType: "application/json"
        )
    )

    #expect(try Data(contentsOf: filePrepared.fileURL) == data)
    #expect(try Data(contentsOf: stagedPrepared.fileURL) == data)
    #expect(try Data(contentsOf: inlinePrepared.fileURL) == data)
    #expect(filePrepared.sizeBytes == UInt64(data.count))
    #expect(stagedPrepared.sizeBytes == UInt64(data.count))
    #expect(inlinePrepared.sizeBytes == UInt64(data.count))

    try access.releasePreparedExport(filePrepared)
    try access.releasePreparedExport(stagedPrepared)
    try access.releasePreparedExport(inlinePrepared)

    #expect(!FileManager.default.fileExists(atPath: filePrepared.fileURL.path))
    #expect(!FileManager.default.fileExists(atPath: stagedPrepared.fileURL.path))
    #expect(!FileManager.default.fileExists(atPath: inlinePrepared.fileURL.path))
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
    #expect(throws: RadrootsAppleFileError.self) {
        _ = try access.stageExternalFile(URL(string: "https://radroots.org/file.json")!, mediaType: nil, filenameHint: nil)
    }
    #expect(throws: RadrootsAppleFileError.self) {
        _ = try access.stageExternalFile(try writeExternalTestFile(name: "bad.txt", data: Data("bad".utf8)), mediaType: nil, filenameHint: "../bad.txt")
    }
    #expect(throws: RadrootsDocumentInterchangeError.self) {
        _ = try access.prepareExport(
            try RadrootsExportDocumentRequest(
                source: .inlineData(Data("bad".utf8)),
                suggestedFilename: "../bad.txt",
                mediaType: "text/plain"
            )
        )
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

private func writeExternalTestFile(name: String, data: Data) throws -> URL {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("radroots-file-access-external-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let url = directory.appendingPathComponent(name)
    try data.write(to: url)
    return url.standardizedFileURL
}
