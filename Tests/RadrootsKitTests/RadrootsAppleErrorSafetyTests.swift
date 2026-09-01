import Foundation
import RadrootsKitTesting
import Testing

@testable import RadrootsKit

@Test func publicAppleErrorsUseClosedPathFreeDescriptions() {
    let errors: [any Error] = [
        RadrootsCaptureIntakeError.invalidRequest,
        RadrootsCaptureIntakeError.unavailable,
        RadrootsCaptureIntakeError.permissionDenied,
        RadrootsCaptureIntakeError.userCancelled,
        RadrootsCaptureIntakeError.transientFailure,
        RadrootsCaptureIntakeError.permanentFailure,
        RadrootsBackgroundTransferError.invalidRequest,
        RadrootsBackgroundTransferError.unavailable,
        RadrootsBackgroundTransferError.transferFailure,
        RadrootsBackgroundTransferError.persistenceFailure,
        RadrootsDocumentInterchangeError.invalidRequest,
        RadrootsDocumentInterchangeError.notFound,
        RadrootsDocumentInterchangeError.userCancelled,
        RadrootsDocumentInterchangeError.permissionDenied,
        RadrootsDocumentInterchangeError.transientFailure,
        RadrootsDocumentInterchangeError.permanentFailure,
        RadrootsAppLocalStateResetError.invalidRequest,
        RadrootsAppLocalStateResetError.fileSystemFailure,
        RadrootsAppLocalStateResetError.keychainFailure,
        RadrootsAppleMediaPreparationError.invalidRequest,
        RadrootsAppleMediaPreparationError.unavailable,
        RadrootsAppleMediaPreparationError.preparationFailure,
        RadrootsTelemetryError.invalidRequest,
        RadrootsExternalActionError.invalidRequest,
        RadrootsExternalActionError.blockedByPolicy,
        RadrootsExternalActionError.unavailable,
        RadrootsExternalActionError.transientFailure,
        RadrootsExternalActionError.permanentFailure,
        RadrootsAppleFileError.invalidRequest,
        RadrootsAppleFileError.notFound,
        RadrootsAppleFileError.permissionDenied,
        RadrootsAppleFileError.transientFailure,
        RadrootsAppleFileError.permanentFailure,
        RadrootsLocationServicesError.invalidRequest,
        RadrootsLocationServicesError.permissionDenied,
        RadrootsLocationServicesError.unavailable,
        RadrootsLocationServicesError.timeout,
        RadrootsLocationServicesError.cancelled,
        RadrootsLocationServicesError.transientFailure,
        RadrootsLocationServicesError.permanentFailure,
        RadrootsUserPresenceError.invalidRequest,
        RadrootsUserPresenceError.userCancelled,
        RadrootsUserPresenceError.permissionDenied,
        RadrootsUserPresenceError.unavailable,
        RadrootsUserPresenceError.timeout,
        RadrootsUserPresenceError.transientFailure,
        RadrootsUserPresenceError.permanentFailure,
        RadrootsBackgroundTaskError.invalidRequest,
        RadrootsBackgroundTaskError.unavailable,
        RadrootsBackgroundTaskError.schedulerFailure,
        RadrootsAppleSecurityError.invalidRequest,
        RadrootsAppleSecurityError.notFound,
        RadrootsAppleSecurityError.permissionDenied,
        RadrootsAppleSecurityError.userCancelled,
        RadrootsAppleSecurityError.transientFailure,
        RadrootsAppleSecurityError.unavailable,
        RadrootsAppleSecurityError.permanentFailure,
        RadrootsAppleSecurityError.keychainFailure,
        RadrootsAppleMobileStoreError.invalidPublicKey,
        RadrootsAppleMobileStoreError.protectedDataUnavailable,
        RadrootsAppleMobileStoreError.invalidDirectoryLayout,
        RadrootsAppleMobileStoreError.fileSystemFailure,
        RadrootsVerifiedArtifactAccessError.invalidDescriptor,
        RadrootsVerifiedArtifactAccessError.protectedDataUnavailable,
        RadrootsVerifiedArtifactAccessError.artifactUnavailable,
        RadrootsVerifiedArtifactAccessError.artifactCorrupt,
        RadrootsVerifiedArtifactAccessError.fileSystemFailure,
    ]
    let forbidden = [
        "/Users/example/private.sqlite",
        "https://secret.example.invalid/token",
        "nsec1secretcanary",
    ]

    for error in errors {
        let renderings = [
            String(describing: error),
            String(reflecting: error),
            (error as NSError).localizedDescription,
        ]
        #expect(renderings.allSatisfy { !$0.isEmpty })
        #expect(
            renderings.allSatisfy { rendering in
                forbidden.allSatisfy { !rendering.contains($0) }
            })
    }
}

@Test func dependencyDiagnosticsCannotBecomePublicErrorText() {
    let canary = NSError(
        domain: "/Users/example/private.sqlite",
        code: 7,
        userInfo: [
            NSLocalizedDescriptionKey:
                "https://secret.example.invalid/token nsec1secretcanary"
        ]
    )

    let captureError = RadrootsAppleMediaPicker.adapt(error: canary)
    #expect(captureError == .transientFailure)
    #expect(!String(reflecting: captureError).contains("private.sqlite"))
    #expect(!(captureError.errorDescription ?? "").contains("secret.example.invalid"))

    #if canImport(LocalAuthentication)
        let presenceError = RadrootsAppleUserPresenceAdapters.adapt(error: canary)
        #expect(presenceError == .permanentFailure)
        #expect(!String(reflecting: presenceError).contains("nsec1secretcanary"))
        #expect(!(presenceError.errorDescription ?? "").contains("secret.example.invalid"))
    #endif
}

@Test func throwingAppleAdaptersMapDependencyDiagnosticsToClosedErrors() async throws {
    let backgroundTasks = RadrootsAppleBackgroundTaskScheduler(
        adapters: RadrootsAppleBackgroundTaskSchedulerAdapters(
            now: { Date(timeIntervalSince1970: 1) },
            register: { _ in throw dependencyCanaryError() },
            submit: { _ in throw dependencyCanaryError() },
            cancel: { _ in },
            cancelAll: {},
            pendingTasks: { throw dependencyCanaryError() }
        )
    )
    let registration = try RadrootsAppleBackgroundTaskRegistration(
        identifier: RadrootsBackgroundTaskIdentifier("org.radroots.error-safety.refresh"),
        kind: .appRefresh,
        handler: { true }
    )
    await #expect(throws: RadrootsBackgroundTaskError.schedulerFailure) {
        _ = try await backgroundTasks.register(registration)
    }
    await #expect(throws: RadrootsBackgroundTaskError.schedulerFailure) {
        _ = try await backgroundTasks.pendingTasks()
    }

    let location = RadrootsAppleLocationServices(
        adapters: RadrootsAppleLocationServicesAdapters(
            now: { Date(timeIntervalSince1970: 1) },
            locationServicesEnabled: { true },
            authorizationStatus: { .notDetermined },
            requestWhenInUseAuthorization: { _ in throw dependencyCanaryError() },
            requestCurrentLocation: { _ in throw dependencyCanaryError() }
        )
    )
    await #expect(throws: RadrootsLocationServicesError.permanentFailure) {
        _ = try await location.requestWhenInUseAuthorization()
    }

    let presence = RadrootsAppleUserPresence(
        adapters: RadrootsAppleUserPresenceAdapters(
            currentStatus: { throw dependencyCanaryError() },
            verify: { _ in throw dependencyCanaryError() }
        )
    )
    await #expect(throws: RadrootsUserPresenceError.permanentFailure) {
        _ = try await presence.currentStatus()
    }
    let request = try RadrootsUserPresenceRequest(reason: "Verify local identity")
    await #expect(throws: RadrootsUserPresenceError.permanentFailure) {
        _ = try await presence.verify(request)
    }

    let transferRequest = try RadrootsBackgroundTransferRequest(
        identifier: RadrootsBackgroundTransferIdentifier("error-safety.transfer"),
        remoteURL: #require(URL(string: "https://radroots.org/error-safety")),
        method: .get,
        operation: .download(
            destination: .file(
                RadrootsFileReference(scope: .cache, relativePath: "error-safety.bin")
            )
        )
    )
    let storageFailure = RadrootsAppleBackgroundTransfer(
        store: ThrowingBackgroundTransferStore(),
        adapters: .unavailable
    )
    await #expect(throws: RadrootsBackgroundTransferError.persistenceFailure) {
        _ = try await storageFailure.enqueue(transferRequest)
    }

    let adapterFailure = RadrootsAppleBackgroundTransfer(
        store: RadrootsInMemoryBackgroundTransferStore(),
        adapters: RadrootsAppleBackgroundTransferAdapters(
            now: { Date(timeIntervalSince1970: 1) },
            enqueue: { _ in throw dependencyCanaryError() },
            cancel: { _ in },
            activeTransferIdentifiers: { [] },
            handleBackgroundEvents: { _, completion in completion() }
        )
    )
    await #expect(throws: RadrootsBackgroundTransferError.transferFailure) {
        _ = try await adapterFailure.enqueue(transferRequest)
    }
}

@Test func fileSystemDiagnosticsCannotEscapeTheClosedFileErrorBoundary() throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("radroots-error-safety-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let invalidDataRoot = root.appendingPathComponent("private.sqlite")
    try Data("not a directory".utf8).write(to: invalidDataRoot)
    let roots = try RadrootsAppleFileRoots(
        appIdentifier: "org.radroots.error-safety",
        dataRoot: invalidDataRoot,
        cacheRoot: root.appendingPathComponent("cache", isDirectory: true),
        temporaryRoot: root.appendingPathComponent("temporary", isDirectory: true)
    )
    let access = RadrootsAppleFileAccess(roots: roots)

    do {
        try access.write(
            .inline(Data("payload".utf8)),
            to: RadrootsFileReference(scope: .data, relativePath: "secret.example.invalid")
        )
        Issue.record("expected the invalid filesystem layout to fail")
    } catch let error as RadrootsAppleFileError {
        #expect(error == .permanentFailure)
        #expect(!String(reflecting: error).contains("private.sqlite"))
        #expect(!(error.errorDescription ?? "").contains("secret.example.invalid"))
    } catch {
        Issue.record("unexpected dependency-owned error: \(type(of: error))")
    }
}

private func dependencyCanaryError() -> NSError {
    NSError(
        domain: "/Users/example/private.sqlite",
        code: 9,
        userInfo: [NSLocalizedDescriptionKey: "https://secret.example.invalid/token"]
    )
}

private actor ThrowingBackgroundTransferStore: RadrootsBackgroundTransferStore {
    func loadSnapshots() async throws -> [RadrootsBackgroundTransferSnapshot] {
        throw dependencyCanaryError()
    }

    func saveSnapshot(_: RadrootsBackgroundTransferSnapshot) async throws {
        throw dependencyCanaryError()
    }

    func removeSnapshot(for _: RadrootsBackgroundTransferIdentifier) async throws {
        throw dependencyCanaryError()
    }

    func removeAllSnapshots() async throws {
        throw dependencyCanaryError()
    }
}
