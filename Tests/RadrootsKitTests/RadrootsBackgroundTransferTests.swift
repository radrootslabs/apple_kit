import Foundation
import Testing

@testable import RadrootsKit

@Test func backgroundTransferIdentifierNormalizesAndRejectsUnsafeValues() throws {
  let identifier = try RadrootsBackgroundTransferIdentifier(" FIELD-IOS.TRANSFER_1 ")

  #expect(identifier.rawValue == "field-ios.transfer_1")

  #expect(
    throws: RadrootsBackgroundTransferError.invalidRequest(
      "background transfer identifier must not be empty")
  ) {
    _ = try RadrootsBackgroundTransferIdentifier(" ")
  }
  #expect(
    throws: RadrootsBackgroundTransferError.invalidRequest(
      "background transfer identifier must use lowercase safe identifier characters"
    )
  ) { _ = try RadrootsBackgroundTransferIdentifier("/escape") }
  #expect(
    throws: RadrootsBackgroundTransferError.invalidRequest(
      "background transfer identifier cannot contain empty path components")
  ) {
    _ = try RadrootsBackgroundTransferIdentifier("field..transfer")
  }
}

@Test func backgroundTransferRequestValidatesUrlMethodAndHeaders() throws {
  let destination = RadrootsBackgroundTransferLocalFile.file(
    RadrootsFileReference(scope: .cache, relativePath: "downloads/relay.json"))
  let request = try RadrootsBackgroundTransferRequest(
    identifier: RadrootsBackgroundTransferIdentifier("field.transfer.download"),
    remoteURL: #require(URL(string: "https://radroots.org/relay.json")), method: .get,
    operation: .download(destination: destination),
    headers: ["Accept": "application/json"], metadata: ["purpose": "diagnostics"]
  )

  #expect(request.method == .get)
  #expect(request.operation == .download(destination: destination))
  #expect(request.headers["Accept"] == "application/json")

  let longAuthorization = String(repeating: "a", count: 2048)
  let authorized = try RadrootsBackgroundTransferRequest(
    remoteURL: #require(URL(string: "https://radroots.org/relay.json")), method: .get,
    operation: .download(destination: destination),
    headers: ["Authorization": longAuthorization]
  )
  #expect(authorized.headers["Authorization"] == longAuthorization)

  #expect(
    throws: RadrootsBackgroundTransferError.invalidRequest(
      "background transfer remote URL must use public HTTPS")
  ) {
    _ = try RadrootsBackgroundTransferRequest(
      remoteURL: #require(URL(string: "http://radroots.org/relay.json")), method: .get,
      operation: .download(destination: destination)
    )
  }
  #expect(
    throws: RadrootsBackgroundTransferError.invalidRequest(
      "background transfer remote URL is unsafe")
  ) {
    _ = try RadrootsBackgroundTransferRequest(
      remoteURL: #require(URL(string: "https://radroots.org/relay.json?token=secret")),
      method: .get,
      operation: .download(destination: destination)
    )
  }
  let simulatorRequest = try RadrootsBackgroundTransferRequest(
    remoteURL: #require(URL(string: "http://127.0.0.1:21100/relay.json")), method: .get,
    operation: .download(destination: destination),
    networkPolicy: .simulatorLoopbackHTTP
  )
  #expect(simulatorRequest.networkPolicy == .simulatorLoopbackHTTP)
  #expect(
    throws: RadrootsBackgroundTransferError.invalidRequest(
      "background download transfers must use GET")
  ) {
    _ = try RadrootsBackgroundTransferRequest(
      remoteURL: #require(URL(string: "https://radroots.org/relay.json")), method: .post,
      operation: .download(destination: destination)
    )
  }
  #expect(
    throws: RadrootsBackgroundTransferError.invalidRequest(
      "background transfer header value cannot contain control characters")
  ) {
    _ = try RadrootsBackgroundTransferRequest(
      remoteURL: #require(URL(string: "https://radroots.org/relay.json")), method: .get,
      operation: .download(destination: destination),
      headers: ["Accept": "application/json\ntext/plain"]
    )
  }
  #expect(
    throws: RadrootsBackgroundTransferError.invalidRequest(
      "background transfer header name is unsafe")
  ) {
    _ = try RadrootsBackgroundTransferRequest(
      remoteURL: #require(URL(string: "https://radroots.org/relay.json")), method: .get,
      operation: .download(destination: destination),
      headers: ["Content-Length": "4"]
    )
  }
}

@Test func backgroundTransferUploadRequiresUploadMethod() throws {
  let source = try RadrootsBackgroundTransferLocalFile.stagedBlob(
    RadrootsStagedBlobReference(blobID: "upload", sizeBytes: 12))

  let request = try RadrootsBackgroundTransferRequest(
    remoteURL: #require(URL(string: "https://radroots.org/upload")), method: .put,
    operation: .upload(source: source)
  )

  #expect(request.operation == .upload(source: source))

  #expect(
    throws: RadrootsBackgroundTransferError.invalidRequest(
      "background upload transfers must use POST or PUT")
  ) {
    _ = try RadrootsBackgroundTransferRequest(
      remoteURL: #require(URL(string: "https://radroots.org/upload")), method: .get,
      operation: .upload(source: source)
    )
  }
}

@Test func backgroundTransferRequestsEnforceTransferByteBounds() throws {
  let destination = RadrootsBackgroundTransferLocalFile.file(
    RadrootsFileReference(scope: .cache, relativePath: "bounded.bin")
  )
  let request = try RadrootsBackgroundTransferRequest(
    remoteURL: #require(URL(string: "https://radroots.org/bounded.bin")),
    method: .get,
    operation: .download(destination: destination),
    maximumTransferBytes: 1024
  )

  #expect(request.maximumTransferBytes == 1024)
  #expect(
    throws: RadrootsBackgroundTransferError.invalidRequest(
      "background transfer byte limit is invalid")
  ) {
    _ = try RadrootsBackgroundTransferRequest(
      remoteURL: #require(URL(string: "https://radroots.org/unbounded.bin")),
      method: .get,
      operation: .download(destination: destination),
      maximumTransferBytes: 0
    )
  }
  #expect(
    throws: RadrootsBackgroundTransferError.invalidRequest(
      "background downloads require a scoped destination file")
  ) {
    _ = try RadrootsBackgroundTransferRequest(
      remoteURL: #require(URL(string: "https://radroots.org/blob.bin")),
      method: .get,
      operation: .download(
        destination: .stagedBlob(try RadrootsStagedBlobReference(blobID: "download", sizeBytes: 1))
      )
    )
  }
}

@Test func backgroundTransferProgressAndSnapshotValidateBounds() throws {
  let request = try testDownloadRequest(identifier: "field.transfer.snapshot")
  let progress = try RadrootsBackgroundTransferProgress(bytesTransferred: 5, totalBytesExpected: 10)
  let snapshot = try RadrootsBackgroundTransferSnapshot(
    request: request, state: .running, progress: progress, errorMessage: " running ",
    updatedAt: Date(timeIntervalSince1970: 1)
  )

  #expect(snapshot.identifier == request.identifier)
  #expect(snapshot.state == .running)
  #expect(snapshot.progress == progress)
  #expect(snapshot.errorMessage == "running")
  #expect(snapshot.response == nil)
  #expect(!snapshot.possibleRemoteOrphan)

  #expect(
    throws: RadrootsBackgroundTransferError.invalidRequest(
      "background transfer expected byte count cannot be less than transferred bytes"
    )
  ) { _ = try RadrootsBackgroundTransferProgress(bytesTransferred: 10, totalBytesExpected: 5) }
  #expect(
    throws: RadrootsBackgroundTransferError.invalidRequest(
      "background transfer updated date must be finite")
  ) {
    _ = try RadrootsBackgroundTransferSnapshot(
      request: request, updatedAt: Date(timeIntervalSinceReferenceDate: .infinity))
  }
}

@Test func backgroundTransferPersistenceRedactsSecretsAndValidatesDecode() async throws {
  let roots = try testBackgroundTransferRoots()
  let store = RadrootsAppleBackgroundTransferStore(roots: roots)
  let request = try RadrootsBackgroundTransferRequest(
    identifier: RadrootsBackgroundTransferIdentifier("field.transfer.redacted"),
    remoteURL: #require(URL(string: "https://radroots.org/upload")),
    method: .put,
    operation: .upload(
      source: .file(RadrootsFileReference(scope: .cache, relativePath: "upload.png"))),
    headers: ["Authorization": "Nostr secret-token"],
    metadata: ["purpose": "blossom_upload", "sha256": String(repeating: "a", count: 64)]
  )
  try await store.saveSnapshot(RadrootsBackgroundTransferSnapshot(request: request))

  let persistedURL = roots.dataRoot.appendingPathComponent("background_transfers/transfers.json")
  let persisted = try String(contentsOf: persistedURL, encoding: .utf8)
  #expect(!request.debugDescription.contains("secret-token"))
  #expect(
    !RadrootsBackgroundTransferHandle(request: request).debugDescription.contains("secret-token"))
  let snapshotDebugDescription = try RadrootsBackgroundTransferSnapshot(request: request)
    .debugDescription
  #expect(!snapshotDebugDescription.contains("secret-token"))
  #expect(!persisted.contains("secret-token"))
  #expect(!persisted.contains("blossom_upload"))
  #expect(!persisted.contains(String(repeating: "a", count: 64)))
  #expect(persisted.contains("\"schemaVersion\":1"))
  let recovered = try #require(try await store.loadSnapshots().first)
  #expect(recovered.request.headers.isEmpty)
  #expect(recovered.request.metadata.isEmpty)

  let malformed = persisted.replacingOccurrences(of: "field.transfer.redacted", with: "../unsafe")
  try Data(malformed.utf8).write(to: persistedURL, options: .atomic)
  await #expect(
    throws: RadrootsBackgroundTransferError.persistenceFailure(
      "background transfer persistence could not be read")
  ) {
    _ = try await store.loadSnapshots()
  }
}

@Test func appleBackgroundTransferStoreMigratesLegacyCachePersistence() async throws {
  let roots = try testBackgroundTransferRoots()
  let legacyURL = roots.cacheRoot.appendingPathComponent("background_transfers/transfers.json")
  try FileManager.default.createDirectory(
    at: legacyURL.deletingLastPathComponent(), withIntermediateDirectories: true)
  let snapshot = try RadrootsBackgroundTransferSnapshot(
    request: testDownloadRequest(identifier: "field.transfer.legacy"))
  try JSONEncoder().encode([snapshot]).write(to: legacyURL, options: .atomic)

  let store = RadrootsAppleBackgroundTransferStore(roots: roots)
  #expect(try await store.loadSnapshots().map(\.identifier.rawValue) == ["field.transfer.legacy"])
  #expect(!FileManager.default.fileExists(atPath: legacyURL.path))
  #expect(
    FileManager.default.fileExists(
      atPath: roots.dataRoot.appendingPathComponent("background_transfers/transfers.json").path))
}

@Test func appleBackgroundTransferStoreFailsClosedWhileProtectedDataIsLocked() async throws {
  let roots = try testBackgroundTransferRoots()
  let store = RadrootsAppleBackgroundTransferStore(
    roots: roots, protectedData: RadrootsProtectedDataProvider { .locked })

  await #expect(
    throws: RadrootsBackgroundTransferError.persistenceFailure(
      "background transfer protected data is unavailable")
  ) {
    _ = try await store.loadSnapshots()
  }
}

@Test func appleBackgroundTransferFileResolverUsesOnlyFileRootsAndStagedBlobs() throws {
  let roots = try testBackgroundTransferRoots()
  let resolver = RadrootsAppleBackgroundTransferFileResolver(roots: roots)
  let file = RadrootsBackgroundTransferLocalFile.file(
    RadrootsFileReference(scope: .data, relativePath: "exports/diagnostics.json"))
  let blob = try RadrootsStagedBlobReference(blobID: "blob-1", sizeBytes: 2)

  #expect(
    try resolver.resolve(file)
      == roots.dataRoot.appendingPathComponent("exports/diagnostics.json").standardizedFileURL)
  #expect(
    try resolver.resolve(.stagedBlob(blob))
      == roots.stagedBlobsRoot.appendingPathComponent("blob-1").standardizedFileURL)

  try FileManager.default.createDirectory(at: roots.dataRoot, withIntermediateDirectories: true)
  let outside = roots.dataRoot.deletingLastPathComponent().appendingPathComponent("outside.bin")
  try Data("outside".utf8).write(to: outside)
  let symlink = roots.dataRoot.appendingPathComponent("escape.bin")
  try FileManager.default.createSymbolicLink(at: symlink, withDestinationURL: outside)
  #expect(
    throws: RadrootsBackgroundTransferError.invalidRequest(
      "background transfer local file resolved outside its root")
  ) {
    _ = try resolver.resolve(.file(RadrootsFileReference(scope: .data, relativePath: "escape.bin")))
  }

  #expect(throws: RadrootsAppleFileError.invalidRequest("file relative path must not be absolute"))
  {
    _ = try resolver.resolve(
      .file(RadrootsFileReference(scope: .data, relativePath: "/tmp/escape")))
  }
  #expect(
    throws: RadrootsAppleFileError.invalidRequest("staged blob id contains invalid characters")
  ) {
    _ = try resolver.resolve(
      .stagedBlob(RadrootsStagedBlobReference(blobID: "../escape", sizeBytes: 1)))
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
    request: testDownloadRequest(identifier: "field.transfer.a"), state: .running,
    updatedAt: Date(timeIntervalSince1970: 3)
  )

  try await store.saveSnapshot(first)
  try await store.saveSnapshot(second)

  let recoveredStore = RadrootsAppleBackgroundTransferStore(roots: roots)
  #expect(
    try await recoveredStore.loadSnapshots().map(\.identifier.rawValue) == [
      "field.transfer.a", "field.transfer.b",
    ])

  try await recoveredStore.removeSnapshot(for: second.identifier)
  #expect(
    try await recoveredStore.loadSnapshots().map(\.identifier.rawValue) == ["field.transfer.b"])

  try await recoveredStore.removeAllSnapshots()
  #expect(try await recoveredStore.loadSnapshots().isEmpty)
}

@Test func appleBackgroundTransferStoreSerializesConcurrentWriters() async throws {
  let roots = try testBackgroundTransferRoots()
  let store = RadrootsAppleBackgroundTransferStore(roots: roots)

  try await withThrowingTaskGroup(of: Void.self) { group in
    for index in 0..<32 {
      group.addTask {
        let request = try testDownloadRequest(identifier: "field.transfer.concurrent-\(index)")
        try await store.saveSnapshot(RadrootsBackgroundTransferSnapshot(request: request))
      }
    }
    try await group.waitForAll()
  }

  #expect(try await store.loadSnapshots().count == 32)
}

@Test func appleBackgroundTransferStorePersistsBoundedResponseAcrossRestart() async throws {
  let roots = try testBackgroundTransferRoots()
  let store = RadrootsAppleBackgroundTransferStore(roots: roots)
  let body = Data(
    #"{"sha256":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"}"#.utf8)
  let request = try RadrootsBackgroundTransferRequest(
    identifier: RadrootsBackgroundTransferIdentifier("field.transfer.descriptor"),
    remoteURL: #require(URL(string: "https://blossom.radroots.org/upload")), method: .put,
    operation: .upload(
      source: .file(RadrootsFileReference(scope: .cache, relativePath: "prepared.png"))),
    responsePolicy: .boundedJSON(maximumBodyBytes: 1024)
  )
  let response = try RadrootsBackgroundTransferResponse(
    statusCode: 200, mediaType: "application/json", body: body)
  try await store.saveSnapshot(
    RadrootsBackgroundTransferSnapshot(request: request, state: .completed, response: response))

  let recovered = try #require(
    try await RadrootsAppleBackgroundTransferStore(roots: roots).loadSnapshots().first)
  #expect(recovered.response?.body == body)
  #expect(recovered.response?.mediaType == "application/json")
}

@Test func unavailableBackgroundTransferThrowsTypedErrors() async throws {
  let transfer = RadrootsUnavailableBackgroundTransfer(
    reason: "missing background transfer support")
  let request = try testDownloadRequest(identifier: "field.transfer.unavailable")

  await #expect(
    throws: RadrootsBackgroundTransferError.unavailable("missing background transfer support")
  ) {
    _ = try await transfer.enqueue(request)
  }
  await #expect(
    throws: RadrootsBackgroundTransferError.unavailable("missing background transfer support")
  ) {
    try await transfer.cancel(request.identifier)
  }
  await #expect(
    throws: RadrootsBackgroundTransferError.unavailable("missing background transfer support")
  ) {
    _ = try await transfer.snapshot(for: request.identifier)
  }
  await #expect(
    throws: RadrootsBackgroundTransferError.unavailable("missing background transfer support")
  ) {
    _ = try await transfer.snapshots()
  }
}

private func testDownloadRequest(identifier: String) throws -> RadrootsBackgroundTransferRequest {
  try RadrootsBackgroundTransferRequest(
    identifier: RadrootsBackgroundTransferIdentifier(identifier),
    remoteURL: URL(string: "https://radroots.org/\(identifier).json")!,
    method: .get,
    operation: .download(
      destination: .file(RadrootsFileReference(scope: .cache, relativePath: "\(identifier).json")))
  )
}

private func testBackgroundTransferRoots() throws -> RadrootsAppleFileRoots {
  let root = FileManager.default.temporaryDirectory.appendingPathComponent(
    "radroots-background-transfer-\(UUID().uuidString)", isDirectory: true
  )
  return try RadrootsAppleFileRoots(
    appIdentifier: "org.radroots.tests",
    dataRoot: root.appendingPathComponent("data", isDirectory: true),
    cacheRoot: root.appendingPathComponent("cache", isDirectory: true),
    temporaryRoot: root.appendingPathComponent("tmp", isDirectory: true)
  )
}
