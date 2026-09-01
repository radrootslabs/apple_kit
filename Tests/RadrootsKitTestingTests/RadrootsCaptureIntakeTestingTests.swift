import Foundation
import RadrootsKit
import RadrootsKitTesting
import Testing

@Test func fakeMediaPickerReturnsConfiguredSupportAndResults() async throws {
    let asset = try testMediaAsset()
    let importResult = try RadrootsMediaImportResult(items: [asset])
    let captureResult = RadrootsMediaCaptureResult(item: asset)
    let picker = try RadrootsFakeMediaPicker(
        support: RadrootsMediaPickerSupport(
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
    let picker = try RadrootsFakeMediaPicker(
        support: RadrootsMediaPickerSupport(
            importAvailable: true,
            cameraCaptureAvailable: true,
            supportedImportKinds: [.image],
            supportedCaptureKinds: [.image],
            multipleSelectionSupported: false
        ),
        importOutcome: .failure(.userCancelled),
        captureOutcome: .success(RadrootsMediaCaptureResult(item: asset))
    )

    await #expect(throws: RadrootsCaptureIntakeError.userCancelled) {
        _ = try await picker.importMedia(RadrootsMediaImportRequest())
    }

    await picker.setCaptureOutcome(.failure(.permissionDenied))

    await #expect(throws: RadrootsCaptureIntakeError.permissionDenied) {
        _ = try await picker.captureMedia(RadrootsMediaCaptureRequest())
    }
}

@Test func fakeDocumentScannerReturnsConfiguredSupportAndResults() async throws {
    let document = try testScannedDocument()
    let scanner = try RadrootsFakeDocumentScanner(
        support: RadrootsDocumentScannerSupport(
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
    let scanner = try RadrootsFakeDocumentScanner(
        support: RadrootsDocumentScannerSupport(
            interactiveScanAvailable: false,
            multiPageSupported: false,
            supportedOutputKinds: []
        ),
        scanOutcome: .failure(.unavailable)
    )

    await #expect(throws: RadrootsCaptureIntakeError.unavailable) {
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
