import Foundation

#if canImport(UIKit)
@preconcurrency import UIKit
#endif

#if canImport(VisionKit)
@preconcurrency import VisionKit
#endif

public final class RadrootsAppleDocumentScanner: RadrootsDocumentScanner, @unchecked Sendable {
    private let fileAccess: RadrootsAppleFileAccess
    private let callbackTimeout: TimeInterval

    #if canImport(UIKit)
    private let viewControllerProvider: RadrootsAppleViewControllerProvider
    #endif

    #if canImport(UIKit)
    public init(
        fileAccess: RadrootsAppleFileAccess,
        callbackTimeout: TimeInterval = 120,
        viewControllerProvider: @escaping RadrootsAppleViewControllerProvider = {
            try RadrootsAppleUIKitPresentation.activeViewController(service: "document scanner")
        }
    ) {
        self.fileAccess = fileAccess
        self.callbackTimeout = callbackTimeout
        self.viewControllerProvider = viewControllerProvider
    }
    #else
    public init(
        fileAccess: RadrootsAppleFileAccess,
        callbackTimeout: TimeInterval = 120
    ) {
        self.fileAccess = fileAccess
        self.callbackTimeout = callbackTimeout
    }
    #endif

    public func currentSupport() async throws -> RadrootsDocumentScannerSupport {
        #if canImport(UIKit) && canImport(VisionKit)
        let available = await MainActor.run {
            VNDocumentCameraViewController.isSupported
        }
        return try RadrootsDocumentScannerSupport(
            interactiveScanAvailable: available,
            multiPageSupported: available,
            supportedOutputKinds: available ? [.pdf] : []
        )
        #else
        return try Self.unavailableSupport()
        #endif
    }

    public func scanDocument(_ request: RadrootsDocumentScanRequest) async throws -> RadrootsScannedDocument {
        #if canImport(UIKit) && canImport(VisionKit)
        let support = try await currentSupport()
        guard support.interactiveScanAvailable else {
            throw RadrootsCaptureIntakeError.unavailable("document scanner is unavailable")
        }
        let presenter = try await MainActor.run {
            try viewControllerProvider()
        }
        let writer = RadrootsAppleDocumentScanWriter(fileAccess: fileAccess)
        let coordinatorID = UUID()
        return try await RadrootsAppleCaptureAsyncSupport.awaitMainActorCallback(
            timeout: callbackTimeout,
            timeoutMessage: "timed out while presenting document scanner"
        ) { completion in
            let controller = VNDocumentCameraViewController()
            let coordinator = RadrootsAppleDocumentScannerCoordinator(
                writer: writer,
                request: request,
                coordinatorID: coordinatorID
            )
            coordinator.completion = completion
            controller.delegate = coordinator
            RadrootsApplePresentationRetainer.shared.store(coordinator, id: coordinatorID)
            presenter.present(controller, animated: true)
        }
        #else
        throw RadrootsCaptureIntakeError.unavailable("document scanner is unavailable")
        #endif
    }

    static func unavailableSupport() throws -> RadrootsDocumentScannerSupport {
        try RadrootsDocumentScannerSupport(
            interactiveScanAvailable: false,
            multiPageSupported: false,
            supportedOutputKinds: []
        )
    }
}

#if canImport(UIKit) && canImport(VisionKit)
@MainActor
private final class RadrootsAppleDocumentScannerCoordinator: NSObject, @preconcurrency VNDocumentCameraViewControllerDelegate {
    var completion: (@Sendable (Result<RadrootsScannedDocument, RadrootsCaptureIntakeError>) -> Void)?

    private let writer: RadrootsAppleDocumentScanWriter
    private let request: RadrootsDocumentScanRequest
    private let coordinatorID: UUID
    private var didResolve: Bool

    init(
        writer: RadrootsAppleDocumentScanWriter,
        request: RadrootsDocumentScanRequest,
        coordinatorID: UUID
    ) {
        self.writer = writer
        self.request = request
        self.coordinatorID = coordinatorID
        self.didResolve = false
    }

    func documentCameraViewControllerDidCancel(_ controller: VNDocumentCameraViewController) {
        controller.dismiss(animated: true)
        finish(.failure(.userCancelled("document scan was cancelled")))
    }

    func documentCameraViewController(
        _ controller: VNDocumentCameraViewController,
        didFailWithError error: Error
    ) {
        controller.dismiss(animated: true)
        finish(.failure(RadrootsAppleMediaPicker.adapt(error: error)))
    }

    func documentCameraViewController(
        _ controller: VNDocumentCameraViewController,
        didFinishWith scan: VNDocumentCameraScan
    ) {
        controller.dismiss(animated: true)
        do {
            let rendered = try Self.renderPDF(scan)
            finish(.success(try writer.persistPDF(
                data: rendered.data,
                pageCount: rendered.pageCount,
                destinationScope: request.destinationScope
            )))
        } catch {
            finish(.failure(RadrootsAppleMediaPicker.adapt(error: error)))
        }
    }

    private static func renderPDF(_ scan: VNDocumentCameraScan) throws -> (data: Data, pageCount: UInt16) {
        let pageCount = scan.pageCount
        guard pageCount > 0 else {
            throw RadrootsCaptureIntakeError.invalidRequest("document scanner requires at least one page")
        }
        guard pageCount <= Int(UInt16.max) else {
            throw RadrootsCaptureIntakeError.invalidRequest("document scanner page count exceeds supported range")
        }
        let images = (0..<pageCount).map { scan.imageOfPage(at: $0) }
        let bounds = pageBounds(images: images)
        let renderer = UIGraphicsPDFRenderer(bounds: bounds)
        let data = renderer.pdfData { context in
            for image in images {
                context.beginPage()
                image.draw(in: aspectFitRect(imageSize: image.size, bounds: bounds))
            }
        }
        guard !data.isEmpty else {
            throw RadrootsCaptureIntakeError.transientFailure("document scanner failed to render a pdf")
        }
        return (data, UInt16(pageCount))
    }

    private static func pageBounds(images: [UIImage]) -> CGRect {
        let fallback = CGSize(width: 612, height: 792)
        let width = images.map(\.size.width).filter { $0 > 0 }.max() ?? fallback.width
        let height = images.map(\.size.height).filter { $0 > 0 }.max() ?? fallback.height
        return CGRect(origin: .zero, size: CGSize(width: width, height: height))
    }

    private static func aspectFitRect(imageSize: CGSize, bounds: CGRect) -> CGRect {
        guard imageSize.width > 0, imageSize.height > 0 else {
            return bounds
        }
        let widthScale = bounds.width / imageSize.width
        let heightScale = bounds.height / imageSize.height
        let scale = min(widthScale, heightScale)
        let scaledSize = CGSize(width: imageSize.width * scale, height: imageSize.height * scale)
        return CGRect(
            origin: CGPoint(
                x: bounds.origin.x + ((bounds.width - scaledSize.width) / 2),
                y: bounds.origin.y + ((bounds.height - scaledSize.height) / 2)
            ),
            size: scaledSize
        )
    }

    private func finish(_ result: Result<RadrootsScannedDocument, RadrootsCaptureIntakeError>) {
        guard !didResolve else { return }
        didResolve = true
        let completion = completion
        self.completion = nil
        RadrootsApplePresentationRetainer.shared.release(id: coordinatorID)
        completion?(result)
    }
}
#endif

private final class RadrootsAppleDocumentScanWriter: @unchecked Sendable {
    private let fileAccess: RadrootsAppleFileAccess

    init(fileAccess: RadrootsAppleFileAccess) {
        self.fileAccess = fileAccess
    }

    func persistPDF(
        data: Data,
        pageCount: UInt16,
        destinationScope: RadrootsFileScope
    ) throws -> RadrootsScannedDocument {
        let file = RadrootsFileReference(
            scope: destinationScope,
            relativePath: "capture_intake/document_scanner/\(UUID().uuidString.lowercased())/scan.pdf"
        )
        try fileAccess.write(.inline(data), to: file)
        return try RadrootsScannedDocument(
            file: file,
            outputKind: .pdf,
            suggestedFilename: "scan.pdf",
            mediaType: "application/pdf",
            pageCount: pageCount,
            sizeBytes: UInt64(data.count),
            capturedAt: Date()
        )
    }
}
