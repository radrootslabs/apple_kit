import Foundation

#if canImport(AVFoundation)
@preconcurrency import AVFoundation
#endif

#if canImport(ImageIO)
import ImageIO
#endif

#if canImport(PhotosUI)
@preconcurrency import PhotosUI
#endif

#if canImport(UIKit)
@preconcurrency import UIKit
#endif

#if canImport(UniformTypeIdentifiers)
import UniformTypeIdentifiers
#endif

#if canImport(UIKit)
public typealias RadrootsAppleViewControllerProvider = @MainActor @Sendable () throws -> UIViewController
#endif

public final class RadrootsAppleMediaPicker: RadrootsMediaPicker, @unchecked Sendable {
    private let fileAccess: RadrootsAppleFileAccess
    private let fileManager: FileManager
    private let callbackTimeout: TimeInterval

    #if canImport(UIKit)
    private let viewControllerProvider: RadrootsAppleViewControllerProvider
    #endif

    #if canImport(UIKit)
    public init(
        fileAccess: RadrootsAppleFileAccess,
        fileManager: FileManager = .default,
        callbackTimeout: TimeInterval = 120,
        viewControllerProvider: @escaping RadrootsAppleViewControllerProvider = {
            try RadrootsAppleUIKitPresentation.activeViewController(service: "media picker")
        }
    ) {
        self.fileAccess = fileAccess
        self.fileManager = fileManager
        self.callbackTimeout = callbackTimeout
        self.viewControllerProvider = viewControllerProvider
    }
    #else
    public init(
        fileAccess: RadrootsAppleFileAccess,
        fileManager: FileManager = .default,
        callbackTimeout: TimeInterval = 120
    ) {
        self.fileAccess = fileAccess
        self.fileManager = fileManager
        self.callbackTimeout = callbackTimeout
    }
    #endif

    public func currentSupport() async throws -> RadrootsMediaPickerSupport {
        #if canImport(UIKit) && canImport(PhotosUI)
        try await MainActor.run {
            try Self.liveSupport()
        }
        #else
        try Self.unavailableSupport()
        #endif
    }

    public func importMedia(_ request: RadrootsMediaImportRequest) async throws -> RadrootsMediaImportResult {
        #if canImport(UIKit) && canImport(PhotosUI)
        let support = try await currentSupport()
        guard support.importAvailable else {
            throw RadrootsCaptureIntakeError.unavailable("media import is unavailable")
        }
        let writer = RadrootsAppleMediaAssetWriter(fileAccess: fileAccess, fileManager: fileManager)
        let presenter = try await MainActor.run {
            try viewControllerProvider()
        }
        let coordinatorID = UUID()
        return try await RadrootsAppleCaptureAsyncSupport.awaitMainActorCallback(
            timeout: callbackTimeout,
            timeoutMessage: "timed out while presenting media import"
        ) { completion in
            var configuration = PHPickerConfiguration(photoLibrary: .shared())
            configuration.selectionLimit = request.selectionLimit
            configuration.filter = .images
            let picker = PHPickerViewController(configuration: configuration)
            let coordinator = RadrootsApplePhotoPickerCoordinator(
                writer: writer,
                request: request,
                coordinatorID: coordinatorID
            )
            coordinator.completion = completion
            picker.delegate = coordinator
            RadrootsApplePresentationRetainer.shared.store(coordinator, id: coordinatorID)
            presenter.present(picker, animated: true)
        }
        #else
        throw RadrootsCaptureIntakeError.unavailable("media import is unavailable")
        #endif
    }

    public func captureMedia(_ request: RadrootsMediaCaptureRequest) async throws -> RadrootsMediaCaptureResult {
        #if canImport(UIKit)
        let support = try await currentSupport()
        guard support.cameraCaptureAvailable else {
            throw RadrootsCaptureIntakeError.unavailable("camera photo capture is unavailable")
        }
        try await Self.requestCameraAccessIfNeeded()
        let writer = RadrootsAppleMediaAssetWriter(fileAccess: fileAccess, fileManager: fileManager)
        let presenter = try await MainActor.run {
            try viewControllerProvider()
        }
        let coordinatorID = UUID()
        return try await RadrootsAppleCaptureAsyncSupport.awaitMainActorCallback(
            timeout: callbackTimeout,
            timeoutMessage: "timed out while presenting camera photo capture"
        ) { completion in
            let picker = UIImagePickerController()
            picker.sourceType = .camera
            picker.mediaTypes = [Self.imageTypeIdentifier()]
            picker.cameraCaptureMode = .photo
            let coordinator = RadrootsAppleCameraCaptureCoordinator(
                writer: writer,
                request: request,
                coordinatorID: coordinatorID
            )
            coordinator.completion = completion
            picker.delegate = coordinator
            RadrootsApplePresentationRetainer.shared.store(coordinator, id: coordinatorID)
            presenter.present(picker, animated: true)
        }
        #else
        throw RadrootsCaptureIntakeError.unavailable("camera photo capture is unavailable")
        #endif
    }

    static func unavailableSupport() throws -> RadrootsMediaPickerSupport {
        try RadrootsMediaPickerSupport(
            importAvailable: false,
            cameraCaptureAvailable: false,
            supportedImportKinds: [],
            supportedCaptureKinds: [],
            multipleSelectionSupported: false
        )
    }

    static func adapt(error: Error) -> RadrootsCaptureIntakeError {
        if let captureError = error as? RadrootsCaptureIntakeError {
            return captureError
        }
        if let fileError = error as? RadrootsAppleFileError {
            return adapt(fileError: fileError)
        }
        return RadrootsCaptureIntakeError.transientFailure((error as NSError).localizedDescription)
    }

    static func adapt(fileError: RadrootsAppleFileError) -> RadrootsCaptureIntakeError {
        switch fileError {
        case .invalidRequest(let message):
            return .invalidRequest(message)
        case .notFound(let message):
            return .transientFailure(message)
        case .permissionDenied(let message):
            return .permissionDenied(message)
        case .transientFailure(let message):
            return .transientFailure(message)
        case .permanentFailure(let message):
            return .permanentFailure(message)
        }
    }
}

#if canImport(UIKit)
private extension RadrootsAppleMediaPicker {
    @MainActor
    static func liveSupport() throws -> RadrootsMediaPickerSupport {
        let cameraAvailable = UIImagePickerController.isSourceTypeAvailable(.camera) &&
            UIImagePickerController.availableMediaTypes(for: .camera)?.contains(imageTypeIdentifier()) == true
        return try RadrootsMediaPickerSupport(
            importAvailable: true,
            cameraCaptureAvailable: cameraAvailable,
            supportedImportKinds: [.image],
            supportedCaptureKinds: cameraAvailable ? [.image] : [],
            multipleSelectionSupported: true
        )
    }

    static func imageTypeIdentifier() -> String {
        #if canImport(UniformTypeIdentifiers)
        UTType.image.identifier
        #else
        "public.image"
        #endif
    }

    static func requestCameraAccessIfNeeded() async throws {
        #if canImport(AVFoundation)
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            return
        case .notDetermined:
            let granted = await AVCaptureDevice.requestAccess(for: .video)
            guard granted else {
                throw RadrootsCaptureIntakeError.permissionDenied("camera access was not granted")
            }
        case .denied:
            throw RadrootsCaptureIntakeError.permissionDenied("camera access is denied")
        case .restricted:
            throw RadrootsCaptureIntakeError.permissionDenied("camera access is restricted")
        @unknown default:
            throw RadrootsCaptureIntakeError.unavailable("camera authorization is unavailable")
        }
        #else
        throw RadrootsCaptureIntakeError.unavailable("camera authorization is unavailable")
        #endif
    }
}

@MainActor
enum RadrootsAppleUIKitPresentation {
    static func activeViewController(service: String) throws -> UIViewController {
        let scenes = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .filter { scene in
                scene.activationState == .foregroundActive || scene.activationState == .foregroundInactive
            }
        let windows = scenes.flatMap(\.windows)
        guard let window = windows.first(where: \.isKeyWindow) ?? windows.first(where: { !$0.isHidden }) else {
            throw RadrootsCaptureIntakeError.unavailable("\(service) requires an active foreground window")
        }
        guard let rootViewController = window.rootViewController else {
            throw RadrootsCaptureIntakeError.unavailable("\(service) requires an active foreground view controller")
        }
        return topViewController(rootViewController)
    }

    private static func topViewController(_ viewController: UIViewController) -> UIViewController {
        if let presentedViewController = viewController.presentedViewController {
            return topViewController(presentedViewController)
        }
        if let navigationController = viewController as? UINavigationController,
           let visibleViewController = navigationController.visibleViewController {
            return topViewController(visibleViewController)
        }
        if let tabBarController = viewController as? UITabBarController,
           let selectedViewController = tabBarController.selectedViewController {
            return topViewController(selectedViewController)
        }
        return viewController
    }
}

@MainActor
private final class RadrootsApplePhotoPickerCoordinator: NSObject, PHPickerViewControllerDelegate {
    var completion: (@Sendable (Result<RadrootsMediaImportResult, RadrootsCaptureIntakeError>) -> Void)?

    private let writer: RadrootsAppleMediaAssetWriter
    private let request: RadrootsMediaImportRequest
    private let coordinatorID: UUID
    private var selectedResults: [PHPickerResult]
    private var didResolve: Bool

    init(
        writer: RadrootsAppleMediaAssetWriter,
        request: RadrootsMediaImportRequest,
        coordinatorID: UUID
    ) {
        self.writer = writer
        self.request = request
        self.coordinatorID = coordinatorID
        self.selectedResults = []
        self.didResolve = false
    }

    func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
        picker.dismiss(animated: true)
        selectedResults = Array(results.prefix(request.selectionLimit))
        guard !selectedResults.isEmpty else {
            finish(.failure(.userCancelled("media import was cancelled")))
            return
        }
        loadResult(at: 0, collected: [])
    }

    private func loadResult(at index: Int, collected: [RadrootsMediaAsset]) {
        guard index < selectedResults.count else {
            do {
                finish(.success(try RadrootsMediaImportResult(items: collected)))
            } catch {
                finish(.failure(RadrootsAppleMediaPicker.adapt(error: error)))
            }
            return
        }
        let provider = selectedResults[index].itemProvider
        let suggestedName = provider.suggestedName ?? "photo"
        guard provider.hasItemConformingToTypeIdentifier(RadrootsAppleMediaPicker.imageTypeIdentifier()) else {
            finish(.failure(.transientFailure("media import could not resolve an image file representation")))
            return
        }
        provider.loadFileRepresentation(forTypeIdentifier: RadrootsAppleMediaPicker.imageTypeIdentifier()) { url, error in
            if let error {
                Task { @MainActor in
                    self.finish(.failure(RadrootsAppleMediaPicker.adapt(error: error)))
                }
                return
            }
            guard let url else {
                Task { @MainActor in
                    self.finish(.failure(.transientFailure("media import finished without an image file representation")))
                }
                return
            }
            let result: Result<RadrootsMediaAsset, RadrootsCaptureIntakeError>
            do {
                result = .success(
                    try self.writer.persistExternalImage(
                        sourceURL: url,
                        source: .libraryImport,
                        destinationScope: self.request.destinationScope,
                        suggestedFilename: suggestedName,
                        mediaTypeHint: self.mediaTypeHint(from: provider)
                    )
                )
            } catch {
                result = .failure(RadrootsAppleMediaPicker.adapt(error: error))
            }
            Task { @MainActor in
                switch result {
                case .success(let asset):
                    var nextCollected = collected
                    nextCollected.append(asset)
                    self.loadResult(at: index + 1, collected: nextCollected)
                case .failure(let error):
                    self.finish(.failure(error))
                }
            }
        }
    }

    private func mediaTypeHint(from provider: NSItemProvider) -> String? {
        #if canImport(UniformTypeIdentifiers)
        provider.registeredTypeIdentifiers
            .compactMap(UTType.init)
            .first(where: { $0.conforms(to: .image) })?
            .preferredMIMEType
        #else
        nil
        #endif
    }

    private func finish(_ result: Result<RadrootsMediaImportResult, RadrootsCaptureIntakeError>) {
        guard !didResolve else { return }
        didResolve = true
        let completion = completion
        self.completion = nil
        RadrootsApplePresentationRetainer.shared.release(id: coordinatorID)
        completion?(result)
    }
}

@MainActor
private final class RadrootsAppleCameraCaptureCoordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
    var completion: (@Sendable (Result<RadrootsMediaCaptureResult, RadrootsCaptureIntakeError>) -> Void)?

    private let writer: RadrootsAppleMediaAssetWriter
    private let request: RadrootsMediaCaptureRequest
    private let coordinatorID: UUID
    private var didResolve: Bool

    init(
        writer: RadrootsAppleMediaAssetWriter,
        request: RadrootsMediaCaptureRequest,
        coordinatorID: UUID
    ) {
        self.writer = writer
        self.request = request
        self.coordinatorID = coordinatorID
        self.didResolve = false
    }

    func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
        picker.dismiss(animated: true)
        finish(.failure(.userCancelled("camera photo capture was cancelled")))
    }

    func imagePickerController(
        _ picker: UIImagePickerController,
        didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]
    ) {
        picker.dismiss(animated: true)
        do {
            finish(.success(try RadrootsMediaCaptureResult(item: buildAsset(info: info))))
        } catch {
            finish(.failure(RadrootsAppleMediaPicker.adapt(error: error)))
        }
    }

    private func buildAsset(info: [UIImagePickerController.InfoKey: Any]) throws -> RadrootsMediaAsset {
        if let imageURL = info[.imageURL] as? URL {
            return try writer.persistExternalImage(
                sourceURL: imageURL,
                source: .cameraCapture,
                destinationScope: request.destinationScope,
                suggestedFilename: imageURL.lastPathComponent,
                mediaTypeHint: nil
            )
        }
        guard let image = (info[.editedImage] as? UIImage) ?? (info[.originalImage] as? UIImage),
              let jpegData = image.jpegData(compressionQuality: 0.92) else {
            throw RadrootsCaptureIntakeError.transientFailure("camera photo capture finished without a usable image")
        }
        return try writer.persistCapturedJPEG(
            data: jpegData,
            image: image,
            destinationScope: request.destinationScope
        )
    }

    private func finish(_ result: Result<RadrootsMediaCaptureResult, RadrootsCaptureIntakeError>) {
        guard !didResolve else { return }
        didResolve = true
        let completion = completion
        self.completion = nil
        RadrootsApplePresentationRetainer.shared.release(id: coordinatorID)
        completion?(result)
    }
}
#endif

@MainActor
final class RadrootsApplePresentationRetainer {
    static let shared = RadrootsApplePresentationRetainer()
    private var retainers: [UUID: AnyObject]

    private init() {
        self.retainers = [:]
    }

    func store(_ retainer: AnyObject, id: UUID) {
        retainers[id] = retainer
    }

    func release(id: UUID) {
        retainers.removeValue(forKey: id)
    }
}

private final class RadrootsAppleMediaAssetWriter: @unchecked Sendable {
    private let fileAccess: RadrootsAppleFileAccess
    private let fileManager: FileManager

    init(fileAccess: RadrootsAppleFileAccess, fileManager: FileManager) {
        self.fileAccess = fileAccess
        self.fileManager = fileManager
    }

    func persistExternalImage(
        sourceURL: URL,
        source: RadrootsMediaSource,
        destinationScope: RadrootsFileScope,
        suggestedFilename: String,
        mediaTypeHint: String?
    ) throws -> RadrootsMediaAsset {
        let filename = try sanitizedFilename(
            suggestedFilename,
            fallbackBasename: "photo",
            fallbackExtension: fallbackExtension(mediaType: mediaTypeHint)
        )
        let file = try destinationFile(source: source, scope: destinationScope, filename: filename)
        let mediaType = try normalizedImageMediaType(mediaTypeHint, filename: filename)
        let imported = try fileAccess.copyExternalFile(
            sourceURL,
            to: file,
            mediaType: mediaType,
            suggestedFilename: filename
        )
        let destinationURL = try fileAccess.roots.resolvedURL(for: imported.file)
        let dimensions = imageDimensions(fileURL: destinationURL)
        return try RadrootsMediaAsset(
            source: source,
            kind: .image,
            file: imported.file,
            mediaType: imported.mediaType ?? mediaType,
            suggestedFilename: imported.suggestedFilename,
            sizeBytes: imported.sizeBytes,
            pixelWidth: dimensions?.width,
            pixelHeight: dimensions?.height,
            capturedAt: Date()
        )
    }

    #if canImport(UIKit)
    func persistCapturedJPEG(
        data: Data,
        image: UIImage,
        destinationScope: RadrootsFileScope
    ) throws -> RadrootsMediaAsset {
        let filename = try sanitizedFilename(
            "captured_photo.jpg",
            fallbackBasename: "captured_photo",
            fallbackExtension: "jpg"
        )
        let file = try destinationFile(source: .cameraCapture, scope: destinationScope, filename: filename)
        try fileAccess.write(.inline(data), to: file)
        return try RadrootsMediaAsset(
            source: .cameraCapture,
            kind: .image,
            file: file,
            mediaType: "image/jpeg",
            suggestedFilename: filename,
            sizeBytes: UInt64(data.count),
            pixelWidth: image.cgImage.map { UInt32($0.width) } ?? positiveRoundedUInt32(image.size.width),
            pixelHeight: image.cgImage.map { UInt32($0.height) } ?? positiveRoundedUInt32(image.size.height),
            capturedAt: Date()
        )
    }
    #endif

    private func destinationFile(
        source: RadrootsMediaSource,
        scope: RadrootsFileScope,
        filename: String
    ) throws -> RadrootsFileReference {
        let namespace: String
        switch source {
        case .libraryImport:
            namespace = "library_import"
        case .cameraCapture:
            namespace = "camera_capture"
        }
        let validatedFilename = try RadrootsCaptureIntakeValidation.normalizedFilename(filename)
        return RadrootsFileReference(
            scope: scope,
            relativePath: "capture_intake/media/\(namespace)/\(UUID().uuidString.lowercased())/\(validatedFilename)"
        )
    }

    private func sanitizedFilename(
        _ value: String,
        fallbackBasename: String,
        fallbackExtension: String
    ) throws -> String {
        let fallback = "\(fallbackBasename).\(fallbackExtension)"
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let lastComponent = URL(fileURLWithPath: trimmed).lastPathComponent
        let raw = lastComponent.isEmpty || lastComponent == "/" ? fallback : lastComponent
        let sanitizedScalars = raw.unicodeScalars.map { scalar -> Character in
            if CharacterSet.controlCharacters.contains(scalar) ||
                scalar == "/" ||
                scalar == "\\" ||
                scalar == "\0" ||
                scalar == ":" {
                return "_"
            }
            return Character(scalar)
        }
        var sanitized = String(sanitizedScalars).trimmingCharacters(in: .whitespacesAndNewlines)
        if sanitized.isEmpty || sanitized == "." || sanitized == ".." {
            sanitized = fallback
        }
        if URL(fileURLWithPath: sanitized).pathExtension.isEmpty {
            sanitized = "\(sanitized).\(fallbackExtension)"
        }
        return try RadrootsCaptureIntakeValidation.normalizedFilename(sanitized)
    }

    private func normalizedImageMediaType(_ mediaType: String?, filename: String) throws -> String {
        if let mediaType {
            return try RadrootsCaptureIntakeValidation.normalizedMediaType(mediaType)
        }
        #if canImport(UniformTypeIdentifiers)
        if let type = UTType(filenameExtension: URL(fileURLWithPath: filename).pathExtension),
           let preferredMIMEType = type.preferredMIMEType {
            return try RadrootsCaptureIntakeValidation.normalizedMediaType(preferredMIMEType)
        }
        #endif
        return "image/jpeg"
    }

    private func fallbackExtension(mediaType: String?) -> String {
        switch mediaType?.lowercased() {
        case "image/png":
            "png"
        case "image/heic":
            "heic"
        case "image/heif":
            "heif"
        default:
            "jpg"
        }
    }

    private func imageDimensions(fileURL: URL) -> (width: UInt32, height: UInt32)? {
        #if canImport(ImageIO)
        guard let imageSource = CGImageSourceCreateWithURL(fileURL as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(imageSource, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? NSNumber,
              let height = properties[kCGImagePropertyPixelHeight] as? NSNumber,
              width.uint32Value > 0,
              height.uint32Value > 0 else {
            return nil
        }
        return (width.uint32Value, height.uint32Value)
        #else
        return nil
        #endif
    }

    private func positiveRoundedUInt32(_ value: Double) -> UInt32? {
        guard value.isFinite, value > 0 else {
            return nil
        }
        return UInt32(value.rounded())
    }
}

enum RadrootsAppleCaptureAsyncSupport {
    static func awaitMainActorCallback<Value: Sendable>(
        timeout: TimeInterval,
        timeoutMessage: String,
        operation: @escaping @MainActor (@escaping @Sendable (Result<Value, RadrootsCaptureIntakeError>) -> Void) -> Void
    ) async throws -> Value {
        try await withCheckedThrowingContinuation { continuation in
            let state = RadrootsAppleCaptureAsyncCallbackState(continuation: continuation)
            let timeoutTask = Task {
                let nanoseconds = UInt64(max(timeout, 0) * 1_000_000_000)
                do {
                    try await Task.sleep(nanoseconds: nanoseconds)
                } catch {
                    return
                }
                state.resolve(.failure(.transientFailure(timeoutMessage)))
            }
            Task { @MainActor in
                operation { result in
                    timeoutTask.cancel()
                    state.resolve(result)
                }
            }
        }
    }
}

private final class RadrootsAppleCaptureAsyncCallbackState<Value: Sendable>: @unchecked Sendable {
    private let lock: NSLock
    private var continuation: CheckedContinuation<Value, any Error>?
    private var didResolve: Bool

    init(continuation: CheckedContinuation<Value, any Error>) {
        self.lock = NSLock()
        self.continuation = continuation
        self.didResolve = false
    }

    func resolve(_ result: Result<Value, RadrootsCaptureIntakeError>) {
        lock.lock()
        guard !didResolve, let continuation else {
            lock.unlock()
            return
        }
        didResolve = true
        self.continuation = nil
        lock.unlock()

        switch result {
        case .success(let value):
            continuation.resume(returning: value)
        case .failure(let error):
            continuation.resume(throwing: error)
        }
    }
}
