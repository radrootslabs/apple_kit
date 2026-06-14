import Foundation
import Testing
import UniformTypeIdentifiers
@testable import RadrootsKit

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

    #expect(textItem.text == "public post")
    #expect(textItem.subject == "Radroots")

    let urlRequest = try RadrootsShareRequest(items: [.url(URL(string: "https://radroots.org/posts/1")!)])
    let urlItem = try RadrootsDocumentPresentationAdapter.transferItem(for: urlRequest)

    #expect(urlItem.text == "https://radroots.org/posts/1")

    let file = RadrootsFileReference(scope: .data, relativePath: "exports/diagnostics.json")
    let fileRequest = try RadrootsShareRequest(
        items: [.file(file, suggestedFilename: "diagnostics.json", mediaType: "application/json", sizeBytes: nil)]
    )

    #expect(throws: RadrootsDocumentInterchangeError.self) {
        _ = try RadrootsDocumentPresentationAdapter.transferItem(for: fileRequest)
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
