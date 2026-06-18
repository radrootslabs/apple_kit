import Foundation
import Testing
@testable import RadrootsKit

@Test func backgroundTransferIdentifierNormalizesAndRejectsUnsafeValues() throws {
    let identifier = try RadrootsBackgroundTransferIdentifier(" FIELD-IOS.TRANSFER_1 ")

    #expect(identifier.rawValue == "field-ios.transfer_1")

    #expect(throws: RadrootsBackgroundTransferError.invalidRequest("background transfer identifier must not be empty")) {
        _ = try RadrootsBackgroundTransferIdentifier(" ")
    }
    #expect(throws: RadrootsBackgroundTransferError.invalidRequest("background transfer identifier must use lowercase safe identifier characters")) {
        _ = try RadrootsBackgroundTransferIdentifier("/escape")
    }
    #expect(throws: RadrootsBackgroundTransferError.invalidRequest("background transfer identifier cannot contain empty path components")) {
        _ = try RadrootsBackgroundTransferIdentifier("field..transfer")
    }
}

@Test func backgroundTransferRequestValidatesUrlMethodAndHeaders() throws {
    let destination = RadrootsBackgroundTransferLocalFile.file(
        RadrootsFileReference(scope: .cache, relativePath: "downloads/relay.json")
    )
    let request = try RadrootsBackgroundTransferRequest(
        identifier: RadrootsBackgroundTransferIdentifier("field.transfer.download"),
        remoteURL: URL(string: "https://radroots.org/relay.json")!,
        method: .get,
        operation: .download(destination: destination),
        headers: ["Accept": "application/json"],
        metadata: ["purpose": "diagnostics"]
    )

    #expect(request.method == .get)
    #expect(request.operation == .download(destination: destination))
    #expect(request.headers["Accept"] == "application/json")

    #expect(throws: RadrootsBackgroundTransferError.invalidRequest("background transfer remote URL must use https with a host and no credentials")) {
        _ = try RadrootsBackgroundTransferRequest(
            remoteURL: URL(string: "http://radroots.org/relay.json")!,
            method: .get,
            operation: .download(destination: destination)
        )
    }
    #expect(throws: RadrootsBackgroundTransferError.invalidRequest("background download transfers must use GET")) {
        _ = try RadrootsBackgroundTransferRequest(
            remoteURL: URL(string: "https://radroots.org/relay.json")!,
            method: .post,
            operation: .download(destination: destination)
        )
    }
    #expect(throws: RadrootsBackgroundTransferError.invalidRequest("background transfer header value cannot contain control characters")) {
        _ = try RadrootsBackgroundTransferRequest(
            remoteURL: URL(string: "https://radroots.org/relay.json")!,
            method: .get,
            operation: .download(destination: destination),
            headers: ["Accept": "application/json\ntext/plain"]
        )
    }
}

@Test func backgroundTransferUploadRequiresUploadMethod() throws {
    let source = RadrootsBackgroundTransferLocalFile.stagedBlob(
        try RadrootsStagedBlobReference(blobID: "upload", sizeBytes: 12)
    )

    let request = try RadrootsBackgroundTransferRequest(
        remoteURL: URL(string: "https://radroots.org/upload")!,
        method: .put,
        operation: .upload(source: source)
    )

    #expect(request.operation == .upload(source: source))

    #expect(throws: RadrootsBackgroundTransferError.invalidRequest("background upload transfers must use POST or PUT")) {
        _ = try RadrootsBackgroundTransferRequest(
            remoteURL: URL(string: "https://radroots.org/upload")!,
            method: .get,
            operation: .upload(source: source)
        )
    }
}

@Test func backgroundTransferProgressAndSnapshotValidateBounds() throws {
    let request = try testDownloadRequest(identifier: "field.transfer.snapshot")
    let progress = try RadrootsBackgroundTransferProgress(bytesTransferred: 5, totalBytesExpected: 10)
    let snapshot = try RadrootsBackgroundTransferSnapshot(
        request: request,
        state: .running,
        progress: progress,
        errorMessage: " running ",
        updatedAt: Date(timeIntervalSince1970: 1)
    )

    #expect(snapshot.identifier == request.identifier)
    #expect(snapshot.state == .running)
    #expect(snapshot.progress == progress)
    #expect(snapshot.errorMessage == "running")

    #expect(throws: RadrootsBackgroundTransferError.invalidRequest("background transfer expected byte count cannot be less than transferred bytes")) {
        _ = try RadrootsBackgroundTransferProgress(bytesTransferred: 10, totalBytesExpected: 5)
    }
    #expect(throws: RadrootsBackgroundTransferError.invalidRequest("background transfer updated date must be finite")) {
        _ = try RadrootsBackgroundTransferSnapshot(
            request: request,
            updatedAt: Date(timeIntervalSinceReferenceDate: .infinity)
        )
    }
}

@Test func appleBackgroundTransferFileResolverUsesOnlyFileRootsAndStagedBlobs() throws {
    let roots = try testBackgroundTransferRoots()
    let resolver = RadrootsAppleBackgroundTransferFileResolver(roots: roots)
    let file = RadrootsBackgroundTransferLocalFile.file(
        RadrootsFileReference(scope: .data, relativePath: "exports/diagnostics.json")
    )
    let blob = try RadrootsStagedBlobReference(blobID: "blob-1", sizeBytes: 2)

    #expect(try resolver.resolve(file) == roots.dataRoot.appendingPathComponent("exports/diagnostics.json").standardizedFileURL)
    #expect(try resolver.resolve(.stagedBlob(blob)) == roots.stagedBlobsRoot.appendingPathComponent("blob-1").standardizedFileURL)

    #expect(throws: RadrootsAppleFileError.invalidRequest("file relative path must not be absolute")) {
        _ = try resolver.resolve(.file(RadrootsFileReference(scope: .data, relativePath: "/tmp/escape")))
    }
    #expect(throws: RadrootsAppleFileError.invalidRequest("staged blob id contains invalid characters")) {
        _ = try resolver.resolve(.stagedBlob(RadrootsStagedBlobReference(blobID: "../escape", sizeBytes: 1)))
    }
}

@Test func appleBackgroundTransferStorePersistsAndRecoversSnapshots() async throws {
    let roots = try testBackgroundTransferRoots()
    let store = RadrootsAppleBackgroundTransferStore(roots: roots)
    let first = try RadrootsBackgroundTransferSnapshot(
        request: testDownloadRequest(identifier: "field.transfer.b"),
        updatedAt: Date(timeIntervalSince1970: 2)
    )
    let second = try RadrootsBackgroundTransferSnapshot(
        request: testDownloadRequest(identifier: "field.transfer.a"),
        state: .running,
        updatedAt: Date(timeIntervalSince1970: 3)
    )

    try await store.saveSnapshot(first)
    try await store.saveSnapshot(second)

    let recoveredStore = RadrootsAppleBackgroundTransferStore(roots: roots)
    #expect(try await recoveredStore.loadSnapshots().map(\.identifier.rawValue) == [
        "field.transfer.a",
        "field.transfer.b"
    ])

    try await recoveredStore.removeSnapshot(for: second.identifier)
    #expect(try await recoveredStore.loadSnapshots().map(\.identifier.rawValue) == ["field.transfer.b"])

    try await recoveredStore.removeAllSnapshots()
    #expect(try await recoveredStore.loadSnapshots().isEmpty)
}

@Test func unavailableBackgroundTransferThrowsTypedErrors() async throws {
    let transfer = RadrootsUnavailableBackgroundTransfer(reason: "missing background transfer support")
    let request = try testDownloadRequest(identifier: "field.transfer.unavailable")

    await #expect(throws: RadrootsBackgroundTransferError.unavailable("missing background transfer support")) {
        _ = try await transfer.enqueue(request)
    }
    await #expect(throws: RadrootsBackgroundTransferError.unavailable("missing background transfer support")) {
        try await transfer.cancel(request.identifier)
    }
    await #expect(throws: RadrootsBackgroundTransferError.unavailable("missing background transfer support")) {
        _ = try await transfer.snapshot(for: request.identifier)
    }
    await #expect(throws: RadrootsBackgroundTransferError.unavailable("missing background transfer support")) {
        _ = try await transfer.snapshots()
    }
}

private func testDownloadRequest(identifier: String) throws -> RadrootsBackgroundTransferRequest {
    try RadrootsBackgroundTransferRequest(
        identifier: RadrootsBackgroundTransferIdentifier(identifier),
        remoteURL: URL(string: "https://radroots.org/\(identifier).json")!,
        method: .get,
        operation: .download(
            destination: .file(RadrootsFileReference(scope: .cache, relativePath: "\(identifier).json"))
        )
    )
}

private func testBackgroundTransferRoots() throws -> RadrootsAppleFileRoots {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("radroots-background-transfer-\(UUID().uuidString)", isDirectory: true)
    return try RadrootsAppleFileRoots(
        appIdentifier: "org.radroots.tests",
        dataRoot: root.appendingPathComponent("data", isDirectory: true),
        cacheRoot: root.appendingPathComponent("cache", isDirectory: true),
        temporaryRoot: root.appendingPathComponent("tmp", isDirectory: true)
    )
}
