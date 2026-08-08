import Foundation
@testable import RadrootsKit
import Testing

@Test func documentImportRequestNormalizesContentKinds() throws {
    let request = try RadrootsDocumentImportRequest(
        allowedContentKinds: [.json, .json, .plainText],
        allowsMultipleSelection: true,
        destinationScope: .cache
    )

    #expect(request.allowedContentKinds == [.json, .plainText])
    #expect(request.allowsMultipleSelection)
    #expect(request.destinationScope == .cache)

    #expect(throws: RadrootsDocumentInterchangeError.self) {
        _ = try RadrootsDocumentImportRequest(allowedContentKinds: [])
    }
}

@Test func documentImportResultRejectsEmptyResultsAndUnsafeMetadata() throws {
    let file = RadrootsFileReference(scope: .temporary, relativePath: "imports/config.json")
    let document = try RadrootsImportedDocument(
        file: file,
        originalURL: URL(fileURLWithPath: "/tmp/config.json"),
        suggestedFilename: " config.json ",
        mediaType: " Application/JSON ",
        sizeBytes: 12
    )

    #expect(document.originalURL == URL(fileURLWithPath: "/tmp/config.json"))
    #expect(document.suggestedFilename == "config.json")
    #expect(document.mediaType == "application/json")
    #expect(try RadrootsDocumentImportResult(documents: [document]).documents == [document])

    #expect(throws: RadrootsDocumentInterchangeError.self) {
        _ = try RadrootsDocumentImportResult(documents: [])
    }
    #expect(throws: RadrootsDocumentInterchangeError.self) {
        _ = try RadrootsImportedDocument(
            file: file,
            originalURL: URL(string: "https://radroots.org/config.json"),
            suggestedFilename: "config.json",
            mediaType: "application/json",
            sizeBytes: 1
        )
    }
    #expect(throws: RadrootsDocumentInterchangeError.self) {
        _ = try RadrootsImportedDocument(
            file: file,
            originalURL: nil,
            suggestedFilename: "../config.json",
            mediaType: "application/json",
            sizeBytes: 1
        )
    }
}

@Test func shareRequestValidatesPublicItems() throws {
    let file = RadrootsFileReference(scope: .cache, relativePath: "exports/diagnostics.json")
    let stagedBlob = try RadrootsStagedBlobReference(
        blobID: "diagnostics",
        sizeBytes: 24,
        mediaType: "application/json",
        filenameHint: "diagnostics.json"
    )
    let request = try RadrootsShareRequest(
        items: [
            .text(" public post "),
            .url(#require(URL(string: "https://radroots.org/posts/1"))),
            .file(file, suggestedFilename: " diagnostics.json ", mediaType: " Application/JSON ", sizeBytes: 24),
            .stagedBlob(stagedBlob, suggestedFilename: " staged.json "),
        ],
        subject: " Radroots "
    )

    #expect(request.subject == "Radroots")
    #expect(request.items.count == 4)
    #expect(request.items[0] == .text("public post"))
    #expect(try request.items[1] == .url(#require(URL(string: "https://radroots.org/posts/1"))))
    #expect(request.items[2] == .file(file, suggestedFilename: "diagnostics.json", mediaType: "application/json", sizeBytes: 24))
    #expect(request.items[3] == .stagedBlob(stagedBlob, suggestedFilename: "staged.json"))

    #expect(throws: RadrootsDocumentInterchangeError.self) {
        _ = try RadrootsShareRequest(items: [])
    }
    #expect(throws: RadrootsDocumentInterchangeError.self) {
        _ = try RadrootsShareRequest(items: [.text("  ")])
    }
    #expect(throws: RadrootsDocumentInterchangeError.self) {
        _ = try RadrootsShareRequest(items: [.url(#require(URL(string: "file:///tmp/private.txt")))])
    }
}

@Test func exportDocumentRequestValidatesFilenameMediaTypeAndByteCounts() throws {
    let inlineData = Data(#"{"relay":"wss://radroots.org"}"#.utf8)
    let inlineRequest = try RadrootsExportDocumentRequest(
        source: .inlineData(inlineData),
        suggestedFilename: " relays.json ",
        mediaType: " Application/JSON "
    )

    #expect(inlineRequest.suggestedFilename == "relays.json")
    #expect(inlineRequest.mediaType == "application/json")
    #expect(inlineRequest.sizeBytes == UInt64(inlineData.count))

    let stagedBlob = try RadrootsStagedBlobReference(blobID: "relay-export", sizeBytes: 64)
    let stagedRequest = try RadrootsExportDocumentRequest(
        source: .stagedBlob(stagedBlob),
        suggestedFilename: "relay-export.json",
        mediaType: "application/json",
        sizeBytes: 64
    )
    #expect(stagedRequest.sizeBytes == 64)

    #expect(throws: RadrootsDocumentInterchangeError.self) {
        _ = try RadrootsExportDocumentRequest(
            source: .inlineData(inlineData),
            suggestedFilename: "/tmp/relays.json",
            mediaType: "application/json"
        )
    }
    #expect(throws: RadrootsDocumentInterchangeError.self) {
        _ = try RadrootsExportDocumentRequest(
            source: .inlineData(inlineData),
            suggestedFilename: "relays.json",
            mediaType: "application json"
        )
    }
    #expect(throws: RadrootsDocumentInterchangeError.self) {
        _ = try RadrootsExportDocumentRequest(
            source: .inlineData(inlineData),
            suggestedFilename: "relays.json",
            mediaType: "application/json",
            sizeBytes: 1
        )
    }
    #expect(throws: RadrootsDocumentInterchangeError.self) {
        _ = try RadrootsExportDocumentRequest(
            source: .stagedBlob(stagedBlob),
            suggestedFilename: "relay-export.json",
            mediaType: "application/json",
            sizeBytes: 1
        )
    }
}

@Test func exportDocumentResultNormalizesPublicMetadata() throws {
    let result = try RadrootsExportDocumentResult(
        exportedFilename: " diagnostics.json ",
        mediaType: " Application/JSON ",
        sizeBytes: 99
    )

    #expect(result.exportedFilename == "diagnostics.json")
    #expect(result.mediaType == "application/json")
    #expect(result.sizeBytes == 99)

    #expect(throws: RadrootsDocumentInterchangeError.self) {
        _ = try RadrootsExportDocumentResult(
            exportedFilename: "bad/name.json",
            mediaType: "application/json",
            sizeBytes: nil
        )
    }
}
