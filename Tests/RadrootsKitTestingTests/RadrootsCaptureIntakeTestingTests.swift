import Foundation
import Testing
import RadrootsKit
import RadrootsKitTesting

@Test func fakeMediaPickerReturnsConfiguredSupportAndResults() async throws {
    let asset = try testMediaAsset()
    let importResult = try RadrootsMediaImportResult(items: [asset])
    let captureResult = RadrootsMediaCaptureResult(item: asset)
    let picker = RadrootsFakeMediaPicker(
        support: try RadrootsMediaPickerSupport(
            importAvailable: true,
            cameraCaptureAvailable: true,
            supportedImportKinds: [.image],
            supportedCaptureKinds: [.image],
            multipleSelectionSupported: true
        ),
        importOutcome: .success(importResult),
        captureOutcome: .success(captureResult)
    )
    let importRequest = try RadrootsMediaImportRequest(selectionLimit: 1)
    let captureRequest = try RadrootsMediaCaptureRequest()

    #expect(try await picker.currentSupport().supportedImportKinds == [.image])
    #expect(try await picker.importMedia(importRequest) == importResult)
    #expect(try await picker.captureMedia(captureRequest) == captureResult)
    #expect(await picker.supportRequestCount == 1)
    #expect(await picker.importRequestCount == 1)
    #expect(await picker.captureRequestCount == 1)
    #expect(await picker.lastImportRequest == importRequest)
    #expect(await picker.lastCaptureRequest == captureRequest)
}

@Test func fakeMediaPickerReturnsTypedFailures() async throws {
    let asset = try testMediaAsset()
    let picker = RadrootsFakeMediaPicker(
        support: try RadrootsMediaPickerSupport(
            importAvailable: true,
            cameraCaptureAvailable: true,
            supportedImportKinds: [.image],
            supportedCaptureKinds: [.image],
            multipleSelectionSupported: false
        ),
        importOutcome: .failure(.userCancelled("media import was cancelled")),
        captureOutcome: .success(RadrootsMediaCaptureResult(item: asset))
    )

    await #expect(throws: RadrootsCaptureIntakeError.userCancelled("media import was cancelled")) {
        _ = try await picker.importMedia(try RadrootsMediaImportRequest())
    }

    await picker.setCaptureOutcome(.failure(.permissionDenied("camera access is denied")))

    await #expect(throws: RadrootsCaptureIntakeError.permissionDenied("camera access is denied")) {
        _ = try await picker.captureMedia(try RadrootsMediaCaptureRequest())
    }
}

@Test func fakeDocumentScannerReturnsConfiguredSupportAndResults() async throws {
    let document = try testScannedDocument()
    let scanner = RadrootsFakeDocumentScanner(
        support: try RadrootsDocumentScannerSupport(
            interactiveScanAvailable: true,
            multiPageSupported: true,
            supportedOutputKinds: [.pdf]
        ),
        scanOutcome: .success(document)
    )
    let request = RadrootsDocumentScanRequest()

    #expect(try await scanner.currentSupport().supportedOutputKinds == [.pdf])
    #expect(try await scanner.scanDocument(request) == document)
    #expect(await scanner.supportRequestCount == 1)
    #expect(await scanner.scanRequestCount == 1)
    #expect(await scanner.lastScanRequest == request)
}

@Test func fakeDocumentScannerReturnsTypedFailures() async throws {
    let scanner = RadrootsFakeDocumentScanner(
        support: try RadrootsDocumentScannerSupport(
            interactiveScanAvailable: false,
            multiPageSupported: false,
            supportedOutputKinds: []
        ),
        scanOutcome: .failure(.unavailable("document scanner unavailable"))
    )

    await #expect(throws: RadrootsCaptureIntakeError.unavailable("document scanner unavailable")) {
        _ = try await scanner.scanDocument(RadrootsDocumentScanRequest())
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

private func testScannedDocument() throws -> RadrootsScannedDocument {
    try RadrootsScannedDocument(
        file: RadrootsFileReference(scope: .temporary, relativePath: "capture/scan.pdf"),
        outputKind: .pdf,
        suggestedFilename: "scan.pdf",
        mediaType: "application/pdf",
        pageCount: 2,
        sizeBytes: 2048,
        capturedAt: Date(timeIntervalSince1970: 11)
    )
}
