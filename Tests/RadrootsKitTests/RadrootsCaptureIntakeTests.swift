import Foundation
@testable import RadrootsKit
import Testing

@Test func mediaImportRequestNormalizesKindsAndSelectionLimit() throws {
    let request = try RadrootsMediaImportRequest(
        allowedMediaKinds: [.image, .image],
        selectionLimit: 2,
        destinationScope: .data
    )

    #expect(request.allowedMediaKinds == [.image])
    #expect(request.selectionLimit == 2)
    #expect(request.destinationScope == .data)
}

@Test func mediaImportRequestRejectsInvalidSelectionLimits() {
    #expect(throws: RadrootsCaptureIntakeError.invalidRequest("media import selection limit must be positive")) {
        _ = try RadrootsMediaImportRequest(selectionLimit: 0)
    }
    #expect(throws: RadrootsCaptureIntakeError.invalidRequest("media import selection limit cannot exceed 100")) {
        _ = try RadrootsMediaImportRequest(selectionLimit: 101)
    }
}

@Test func mediaPickerSupportOmitsKindsWhenUnavailable() throws {
    let support = try RadrootsMediaPickerSupport(
        importAvailable: false,
        cameraCaptureAvailable: false,
        supportedImportKinds: [.image],
        supportedCaptureKinds: [.image],
        multipleSelectionSupported: true
    )

    #expect(!support.importAvailable)
    #expect(!support.cameraCaptureAvailable)
    #expect(support.supportedImportKinds.isEmpty)
    #expect(support.supportedCaptureKinds.isEmpty)
    #expect(support.multipleSelectionSupported)
}

@Test func mediaAssetNormalizesMetadata() throws {
    let asset = try RadrootsMediaAsset(
        source: .libraryImport,
        kind: .image,
        file: RadrootsFileReference(scope: .temporary, relativePath: "capture/photo.jpg"),
        mediaType: " Image/JPEG ",
        suggestedFilename: " photo.jpg ",
        sizeBytes: 12,
        pixelWidth: 640,
        pixelHeight: 480,
        capturedAt: Date(timeIntervalSince1970: 10)
    )

    #expect(asset.mediaType == "image/jpeg")
    #expect(asset.suggestedFilename == "photo.jpg")
    #expect(asset.pixelWidth == 640)
    #expect(asset.pixelHeight == 480)
    #expect(asset.capturedAt == Date(timeIntervalSince1970: 10))
}

@Test func mediaAssetRejectsUnsafeMetadata() {
    #expect(throws: RadrootsCaptureIntakeError.invalidRequest("capture filename cannot contain path separators")) {
        _ = try RadrootsMediaAsset(
            source: .libraryImport,
            kind: .image,
            file: RadrootsFileReference(scope: .temporary, relativePath: "capture/photo.jpg"),
            mediaType: "image/jpeg",
            suggestedFilename: "../photo.jpg",
            sizeBytes: 12,
            capturedAt: Date(timeIntervalSince1970: 10)
        )
    }
    #expect(throws: RadrootsCaptureIntakeError.invalidRequest("capture media type must be type/subtype")) {
        _ = try RadrootsMediaAsset(
            source: .libraryImport,
            kind: .image,
            file: RadrootsFileReference(scope: .temporary, relativePath: "capture/photo.jpg"),
            mediaType: "image",
            suggestedFilename: "photo.jpg",
            sizeBytes: 12,
            capturedAt: Date(timeIntervalSince1970: 10)
        )
    }
    #expect(throws: RadrootsCaptureIntakeError.invalidRequest("image dimensions must include width and height together")) {
        _ = try RadrootsMediaAsset(
            source: .libraryImport,
            kind: .image,
            file: RadrootsFileReference(scope: .temporary, relativePath: "capture/photo.jpg"),
            mediaType: "image/jpeg",
            suggestedFilename: "photo.jpg",
            sizeBytes: 12,
            pixelWidth: 640,
            capturedAt: Date(timeIntervalSince1970: 10)
        )
    }
}

@Test func mediaImportResultRequiresAtLeastOneItem() throws {
    let asset = try testMediaAsset()
    let result = try RadrootsMediaImportResult(items: [asset])

    #expect(result.items == [asset])
    #expect(throws: RadrootsCaptureIntakeError.invalidRequest("media import result cannot be empty")) {
        _ = try RadrootsMediaImportResult(items: [])
    }
}

@Test func scannerSupportOmitsOutputKindsWhenUnavailable() throws {
    let support = try RadrootsDocumentScannerSupport(
        interactiveScanAvailable: false,
        multiPageSupported: true,
        supportedOutputKinds: [.pdf]
    )

    #expect(!support.interactiveScanAvailable)
    #expect(!support.multiPageSupported)
    #expect(support.supportedOutputKinds.isEmpty)
}

@Test func scannedDocumentNormalizesPdfMetadata() throws {
    let document = try RadrootsScannedDocument(
        file: RadrootsFileReference(scope: .temporary, relativePath: "capture/scan.pdf"),
        outputKind: .pdf,
        suggestedFilename: " scan.pdf ",
        mediaType: " Application/PDF ",
        pageCount: 2,
        sizeBytes: 2048,
        capturedAt: Date(timeIntervalSince1970: 11)
    )

    #expect(document.suggestedFilename == "scan.pdf")
    #expect(document.mediaType == "application/pdf")
    #expect(document.pageCount == 2)
    #expect(document.sizeBytes == 2048)
}

@Test func scannedDocumentRejectsEmptyPageCount() {
    #expect(throws: RadrootsCaptureIntakeError.invalidRequest("scanned document page count must be positive")) {
        _ = try RadrootsScannedDocument(
            file: RadrootsFileReference(scope: .temporary, relativePath: "capture/scan.pdf"),
            outputKind: .pdf,
            suggestedFilename: "scan.pdf",
            mediaType: "application/pdf",
            pageCount: 0,
            sizeBytes: 2048,
            capturedAt: Date(timeIntervalSince1970: 11)
        )
    }
}

private func testMediaAsset() throws -> RadrootsMediaAsset {
    try RadrootsMediaAsset(
        source: .libraryImport,
        kind: .image,
        file: RadrootsFileReference(scope: .temporary, relativePath: "capture/photo.jpg"),
        mediaType: "image/jpeg",
        suggestedFilename: "photo.jpg",
        sizeBytes: 12,
        capturedAt: Date(timeIntervalSince1970: 10)
    )
}
