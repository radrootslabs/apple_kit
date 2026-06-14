import Foundation
import Testing
@testable import RadrootsKit

#if !canImport(UIKit)
@Test func appleMediaPickerReportsUnavailableWithoutUIKit() async throws {
    let picker = try RadrootsAppleMediaPicker(fileAccess: mediaPickerTestFileAccess())
    let support = try await picker.currentSupport()

    #expect(!support.importAvailable)
    #expect(!support.cameraCaptureAvailable)
    #expect(support.supportedImportKinds.isEmpty)
    #expect(support.supportedCaptureKinds.isEmpty)

    await #expect(throws: RadrootsCaptureIntakeError.unavailable("media import is unavailable")) {
        _ = try await picker.importMedia(try RadrootsMediaImportRequest())
    }
    await #expect(throws: RadrootsCaptureIntakeError.unavailable("camera photo capture is unavailable")) {
        _ = try await picker.captureMedia(try RadrootsMediaCaptureRequest())
    }
}
#endif

private func mediaPickerTestFileAccess() throws -> RadrootsAppleFileAccess {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("radroots-media-picker-\(UUID().uuidString)", isDirectory: true)
    let roots = try RadrootsAppleFileRoots(
        appIdentifier: "org.radroots.media-picker-test",
        dataRoot: root.appendingPathComponent("data", isDirectory: true),
        cacheRoot: root.appendingPathComponent("cache", isDirectory: true),
        temporaryRoot: root.appendingPathComponent("temporary", isDirectory: true)
    )
    return RadrootsAppleFileAccess(roots: roots)
}
