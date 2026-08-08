import Foundation
@testable import RadrootsKit
import Testing

@Test func fileRootsDeriveDefaultLogsAndStagedBlobRoots() throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("radroots-file-roots-\(UUID().uuidString)", isDirectory: true)
    let roots = try RadrootsAppleFileRoots(
        appIdentifier: " org.radroots.tests ",
        dataRoot: root.appendingPathComponent("data", isDirectory: true),
        cacheRoot: root.appendingPathComponent("cache", isDirectory: true),
        temporaryRoot: root.appendingPathComponent("tmp", isDirectory: true)
    )

    #expect(roots.appIdentifier == "org.radroots.tests")
    #expect(roots.logsRoot == roots.cacheRoot.appendingPathComponent("Logs", isDirectory: true).standardizedFileURL)
    #expect(roots.stagedBlobsRoot == roots.temporaryRoot.appendingPathComponent("staged_blobs", isDirectory: true).standardizedFileURL)
}

@Test func fileRootsRejectBlankAppIdentifier() throws {
    let root = FileManager.default.temporaryDirectory
    #expect(throws: RadrootsAppleFileError.self) {
        _ = try RadrootsAppleFileRoots(
            appIdentifier: " ",
            dataRoot: root,
            cacheRoot: root,
            temporaryRoot: root
        )
    }
}

@Test func fileRootsRejectNonFileURLs() throws {
    let root = FileManager.default.temporaryDirectory
    #expect(throws: RadrootsAppleFileError.self) {
        _ = try RadrootsAppleFileRoots(
            appIdentifier: "org.radroots.tests",
            dataRoot: #require(URL(string: "https://radroots.org/data")),
            cacheRoot: root,
            temporaryRoot: root
        )
    }
}

@Test func fileReferenceResolvesInsideSelectedScope() throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("radroots-file-roots-\(UUID().uuidString)", isDirectory: true)
    let roots = try RadrootsAppleFileRoots(
        appIdentifier: "org.radroots.tests",
        dataRoot: root.appendingPathComponent("data", isDirectory: true),
        cacheRoot: root.appendingPathComponent("cache", isDirectory: true),
        temporaryRoot: root.appendingPathComponent("tmp", isDirectory: true)
    )
    let file = RadrootsFileReference(scope: .data, relativePath: "identity/public.json")

    #expect(try roots.resolvedURL(for: file) == roots.dataRoot.appendingPathComponent("identity/public.json").standardizedFileURL)
}

@Test func fileReferenceRejectsAbsolutePath() throws {
    let roots = try testFileRoots()
    let file = RadrootsFileReference(scope: .cache, relativePath: "/tmp/escape")

    #expect(throws: RadrootsAppleFileError.self) {
        _ = try roots.resolvedURL(for: file)
    }
}

@Test func fileReferenceRejectsPathTraversal() throws {
    let roots = try testFileRoots()
    let file = RadrootsFileReference(scope: .data, relativePath: "../escape")

    #expect(throws: RadrootsAppleFileError.self) {
        _ = try roots.resolvedURL(for: file)
    }
}

@Test func fileReferenceAllowsRootOnlyWhenRequested() throws {
    let roots = try testFileRoots()
    let rootFile = RadrootsFileReference(scope: .logs, relativePath: " ")

    #expect(try roots.resolvedURL(for: rootFile, allowRootDirectory: true) == roots.logsRoot)
    #expect(throws: RadrootsAppleFileError.self) {
        _ = try roots.resolvedURL(for: rootFile)
    }
}

private func testFileRoots() throws -> RadrootsAppleFileRoots {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("radroots-file-roots-\(UUID().uuidString)", isDirectory: true)
    return try RadrootsAppleFileRoots(
        appIdentifier: "org.radroots.tests",
        dataRoot: root.appendingPathComponent("data", isDirectory: true),
        cacheRoot: root.appendingPathComponent("cache", isDirectory: true),
        temporaryRoot: root.appendingPathComponent("tmp", isDirectory: true)
    )
}
