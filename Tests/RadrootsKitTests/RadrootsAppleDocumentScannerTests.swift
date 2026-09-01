import Foundation
import Testing

@testable import RadrootsKit

#if !(canImport(UIKit) && canImport(VisionKit))
    @Test func appleDocumentScannerReportsUnavailableWithoutVisionKitScanner() async throws {
        let scanner = try RadrootsAppleDocumentScanner(fileAccess: documentScannerTestFileAccess())
        let support = try await scanner.currentSupport()

        #expect(!support.interactiveScanAvailable)
        #expect(!support.multiPageSupported)
        #expect(support.supportedOutputKinds.isEmpty)

        await #expect(throws: RadrootsCaptureIntakeError.unavailable) {
            _ = try await scanner.scanDocument(RadrootsDocumentScanRequest())
        }
    }
#endif

private func documentScannerTestFileAccess() throws -> RadrootsAppleFileAccess {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("radroots-document-scanner-\(UUID().uuidString)", isDirectory: true)
    let roots = try RadrootsAppleFileRoots(
        appIdentifier: "org.radroots.document-scanner-test",
        dataRoot: root.appendingPathComponent("data", isDirectory: true),
        cacheRoot: root.appendingPathComponent("cache", isDirectory: true),
        temporaryRoot: root.appendingPathComponent("temporary", isDirectory: true)
    )
    return RadrootsAppleFileAccess(roots: roots)
}
