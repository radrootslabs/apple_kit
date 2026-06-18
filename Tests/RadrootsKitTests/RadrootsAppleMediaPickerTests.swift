import Foundation
import Testing
@testable import RadrootsKit

@Test func captureAsyncSupportRunsCleanupOnTimeout() async throws {
    let probe = RadrootsCaptureCleanupProbe()

    await #expect(throws: RadrootsCaptureIntakeError.transientFailure("timeout")) {
        let _: Int = try await RadrootsAppleCaptureAsyncSupport.awaitMainActorCallback(
            timeout: 0.001,
            timeoutMessage: "timeout"
        ) { _, setCleanup in
            setCleanup {
                probe.recordCleanup()
            }
        }
    }

    try await Task.sleep(nanoseconds: 20_000_000)
    #expect(await probe.cleanupCount == 1)
}

@Test func captureAsyncSupportRunsCleanupOnceOnDoubleCompletion() async throws {
    let probe = RadrootsCaptureCleanupProbe()

    let value: Int = try await RadrootsAppleCaptureAsyncSupport.awaitMainActorCallback(
        timeout: 10,
        timeoutMessage: "timeout"
    ) { completion, setCleanup in
        setCleanup {
            probe.recordCleanup()
        }
        completion(.success(7))
        completion(.success(8))
    }

    try await Task.sleep(nanoseconds: 20_000_000)
    #expect(value == 7)
    #expect(await probe.cleanupCount == 1)
}

@Test func captureAsyncSupportRunsCleanupOnTaskCancellation() async throws {
    let probe = RadrootsCaptureCleanupProbe()
    let task = Task<Int, any Error> {
        try await RadrootsAppleCaptureAsyncSupport.awaitMainActorCallback(
            timeout: 10,
            timeoutMessage: "timeout"
        ) { _, setCleanup in
            setCleanup {
                probe.recordCleanup()
            }
        }
    }

    task.cancel()

    await #expect(throws: RadrootsCaptureIntakeError.userCancelled("capture request was cancelled")) {
        _ = try await task.value
    }
    try await Task.sleep(nanoseconds: 20_000_000)
    #expect(await probe.cleanupCount == 1)
}

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

@MainActor
private final class RadrootsCaptureCleanupProbe {
    private(set) var cleanupCount = 0

    func recordCleanup() {
        cleanupCount += 1
    }
}
