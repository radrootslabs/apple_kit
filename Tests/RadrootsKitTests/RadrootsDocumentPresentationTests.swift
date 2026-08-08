import Foundation
@testable import RadrootsKit
import Testing
import UniformTypeIdentifiers

@Test func documentPresentationMapsImportContentTypes() throws {
    let request = try RadrootsDocumentImportRequest(
        allowedContentKinds: [.json, .plainText, .url, .file, .stagedBlob]
    )

    let types = RadrootsDocumentPresentationAdapter.contentTypes(for: request)

    #expect(types == [.json, .plainText, .url, .item, .data])
    #expect(RadrootsDocumentPresentationAdapter.contentType(forMediaType: "application/json") == .json)
    #expect(RadrootsDocumentPresentationAdapter.contentType(forMediaType: "text/plain") == .plainText)
    #expect(RadrootsDocumentPresentationAdapter.contentType(forMediaType: nil) == .data)
}

@Test func documentPresentationBuildsImportDestinations() throws {
    let destination = try RadrootsDocumentPresentationAdapter.importDestination(
        sourceURL: URL(fileURLWithPath: "/tmp/relays.json"),
        scope: .data,
        importID: "import_1"
    )

    #expect(destination.scope == .data)
    #expect(destination.relativePath == "document_import/import_1/relays.json")

    #expect(throws: RadrootsDocumentInterchangeError.self) {
        _ = try RadrootsDocumentPresentationAdapter.importDestination(
            sourceURL: URL(fileURLWithPath: "/tmp/../bad.json"),
            scope: .data,
            importID: "../escape"
        )
    }
}

@Test func documentPresentationAdaptsPublicShareItems() throws {
    let textRequest = try RadrootsShareRequest(items: [.text(" public post ")], subject: " Radroots ")
    let textItem = try RadrootsDocumentPresentationAdapter.transferItem(for: textRequest)

    #expect(textItem.payload == .text("public post"))
    #expect(textItem.text == "public post")
    #expect(textItem.subject == "Radroots")

    let urlRequest = try RadrootsShareRequest(items: [.url(#require(URL(string: "https://radroots.org/posts/1")))])
    let urlItem = try RadrootsDocumentPresentationAdapter.transferItem(for: urlRequest)

    #expect(try urlItem.payload == .url(#require(URL(string: "https://radroots.org/posts/1"))))
    #expect(urlItem.text == "https://radroots.org/posts/1")

    let file = RadrootsFileReference(scope: .data, relativePath: "exports/diagnostics.json")
    let fileRequest = try RadrootsShareRequest(
        items: [.file(file, suggestedFilename: "diagnostics.json", mediaType: "application/json", sizeBytes: nil)]
    )

    #expect(throws: RadrootsDocumentInterchangeError.self) {
        _ = try RadrootsDocumentPresentationAdapter.transferItem(for: fileRequest)
    }
}

@Test func documentPresentationPreparesScopedFileShareItems() throws {
    let access = try testDocumentPresentationFileAccess()
    let file = RadrootsFileReference(scope: .data, relativePath: "exports/diagnostics.json")
    let data = Data(#"{"status":"ok"}"#.utf8)
    try access.write(.inline(data), to: file)
    let request = try RadrootsShareRequest(
        items: [
            .file(
                file,
                suggestedFilename: " diagnostics.json ",
                mediaType: " Application/JSON ",
                sizeBytes: UInt64(data.count)
            ),
        ],
        subject: " Radroots "
    )

    let item = try RadrootsDocumentPresentationAdapter.transferItem(for: request, fileAccess: access)
    guard let prepared = item.preparedExport else {
        Issue.record("expected prepared file share item")
        return
    }

    #expect(item.subject == "Radroots")
    #expect(prepared.suggestedFilename == "diagnostics.json")
    #expect(prepared.mediaType == "application/json")
    #expect(prepared.sizeBytes == UInt64(data.count))
    #expect(try Data(contentsOf: prepared.fileURL) == data)
    #expect(try access.preparedExportExists(prepared))
}

@Test func documentPresentationPreparesStagedBlobShareItems() throws {
    let access = try testDocumentPresentationFileAccess()
    let data = Data("staged export".utf8)
    let staged = try access.stageBlob(
        data,
        mediaType: "text/plain",
        filenameHint: "staged-note.txt"
    )
    let request = try RadrootsShareRequest(
        items: [.stagedBlob(staged, suggestedFilename: nil)],
        subject: nil
    )

    let item = try RadrootsDocumentPresentationAdapter.transferItem(for: request, fileAccess: access)
    guard let prepared = item.preparedExport else {
        Issue.record("expected prepared staged blob share item")
        return
    }

    #expect(prepared.suggestedFilename == "staged-note.txt")
    #expect(prepared.mediaType == "text/plain")
    #expect(prepared.sizeBytes == UInt64(data.count))
    #expect(try Data(contentsOf: prepared.fileURL) == data)
}

@Test func documentPresentationRejectsUnsafeShareFilesAndSecretMaterial() throws {
    #expect(throws: RadrootsDocumentInterchangeError.self) {
        _ = try RadrootsShareRequest(
            items: [
                .file(
                    RadrootsFileReference(scope: .data, relativePath: "/tmp/private.txt"),
                    suggestedFilename: "private.txt",
                    mediaType: "text/plain",
                    sizeBytes: nil
                ),
            ]
        )
    }
    #expect(throws: RadrootsDocumentInterchangeError.self) {
        _ = try RadrootsShareRequest(items: [.text("nostr:nsec1qqqqqq")])
    }
    #expect(throws: RadrootsDocumentInterchangeError.self) {
        _ = try RadrootsShareRequest(
            items: [
                .file(
                    RadrootsFileReference(scope: .data, relativePath: "identity/public.json"),
                    suggestedFilename: "selected_secret_hex.json",
                    mediaType: "application/json",
                    sizeBytes: nil
                ),
            ]
        )
    }
}

@Test func preparedExportFileDocumentWrapsPreparedExportURL() throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("radroots-prepared-export-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let fileURL = directory.appendingPathComponent("diagnostics.json")
    let data = Data(#"{"status":"ok"}"#.utf8)
    try data.write(to: fileURL)
    let prepared = try RadrootsPreparedExportDocument(
        preparedID: "prepared_1",
        fileURL: fileURL,
        suggestedFilename: "diagnostics.json",
        mediaType: "application/json",
        sizeBytes: UInt64(data.count)
    )

    let document = RadrootsPreparedExportFileDocument(preparedExport: prepared)

    #expect(document.fileURL == fileURL.standardizedFileURL)
    #expect(RadrootsPreparedExportFileDocument.readableContentTypes == [.data])
}

private func testDocumentPresentationFileAccess() throws -> RadrootsAppleFileAccess {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("radroots-document-presentation-\(UUID().uuidString)", isDirectory: true)
    let roots = try RadrootsAppleFileRoots(
        appIdentifier: "org.radroots.document-presentation.tests",
        dataRoot: root.appendingPathComponent("data", isDirectory: true),
        cacheRoot: root.appendingPathComponent("cache", isDirectory: true),
        temporaryRoot: root.appendingPathComponent("tmp", isDirectory: true)
    )
    return RadrootsAppleFileAccess(roots: roots)
}
