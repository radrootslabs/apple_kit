import Foundation
import RadrootsKit

public actor RadrootsFakeMediaPicker: RadrootsMediaPicker {
    private var support: RadrootsMediaPickerSupport
    private var importOutcome: Result<RadrootsMediaImportResult, RadrootsCaptureIntakeError>
    private var captureOutcome: Result<RadrootsMediaCaptureResult, RadrootsCaptureIntakeError>
    private var importRequestCountValue: Int
    private var captureRequestCountValue: Int
    private var supportRequestCountValue: Int
    private var lastImportRequestValue: RadrootsMediaImportRequest?
    private var lastCaptureRequestValue: RadrootsMediaCaptureRequest?

    public init(
        support: RadrootsMediaPickerSupport,
        importOutcome: Result<RadrootsMediaImportResult, RadrootsCaptureIntakeError>,
        captureOutcome: Result<RadrootsMediaCaptureResult, RadrootsCaptureIntakeError>
    ) {
        self.support = support
        self.importOutcome = importOutcome
        self.captureOutcome = captureOutcome
        self.importRequestCountValue = 0
        self.captureRequestCountValue = 0
        self.supportRequestCountValue = 0
        self.lastImportRequestValue = nil
        self.lastCaptureRequestValue = nil
    }

    public func setSupport(_ support: RadrootsMediaPickerSupport) {
        self.support = support
    }

    public func setImportOutcome(_ outcome: Result<RadrootsMediaImportResult, RadrootsCaptureIntakeError>) {
        self.importOutcome = outcome
    }

    public func setCaptureOutcome(_ outcome: Result<RadrootsMediaCaptureResult, RadrootsCaptureIntakeError>) {
        self.captureOutcome = outcome
    }

    public func currentSupport() async throws -> RadrootsMediaPickerSupport {
        supportRequestCountValue += 1
        return support
    }

    public func importMedia(_ request: RadrootsMediaImportRequest) async throws -> RadrootsMediaImportResult {
        importRequestCountValue += 1
        lastImportRequestValue = request
        switch importOutcome {
        case .success(let result):
            return result
        case .failure(let error):
            throw error
        }
    }

    public func captureMedia(_ request: RadrootsMediaCaptureRequest) async throws -> RadrootsMediaCaptureResult {
        captureRequestCountValue += 1
        lastCaptureRequestValue = request
        switch captureOutcome {
        case .success(let result):
            return result
        case .failure(let error):
            throw error
        }
    }

    public var supportRequestCount: Int {
        supportRequestCountValue
    }

    public var importRequestCount: Int {
        importRequestCountValue
    }

    public var captureRequestCount: Int {
        captureRequestCountValue
    }

    public var lastImportRequest: RadrootsMediaImportRequest? {
        lastImportRequestValue
    }

    public var lastCaptureRequest: RadrootsMediaCaptureRequest? {
        lastCaptureRequestValue
    }
}

public actor RadrootsFakeDocumentScanner: RadrootsDocumentScanner {
    private var support: RadrootsDocumentScannerSupport
    private var scanOutcome: Result<RadrootsScannedDocument, RadrootsCaptureIntakeError>
    private var supportRequestCountValue: Int
    private var scanRequestCountValue: Int
    private var lastScanRequestValue: RadrootsDocumentScanRequest?

    public init(
        support: RadrootsDocumentScannerSupport,
        scanOutcome: Result<RadrootsScannedDocument, RadrootsCaptureIntakeError>
    ) {
        self.support = support
        self.scanOutcome = scanOutcome
        self.supportRequestCountValue = 0
        self.scanRequestCountValue = 0
        self.lastScanRequestValue = nil
    }

    public func setSupport(_ support: RadrootsDocumentScannerSupport) {
        self.support = support
    }

    public func setScanOutcome(_ outcome: Result<RadrootsScannedDocument, RadrootsCaptureIntakeError>) {
        self.scanOutcome = outcome
    }

    public func currentSupport() async throws -> RadrootsDocumentScannerSupport {
        supportRequestCountValue += 1
        return support
    }

    public func scanDocument(_ request: RadrootsDocumentScanRequest) async throws -> RadrootsScannedDocument {
        scanRequestCountValue += 1
        lastScanRequestValue = request
        switch scanOutcome {
        case .success(let document):
            return document
        case .failure(let error):
            throw error
        }
    }

    public var supportRequestCount: Int {
        supportRequestCountValue
    }

    public var scanRequestCount: Int {
        scanRequestCountValue
    }

    public var lastScanRequest: RadrootsDocumentScanRequest? {
        lastScanRequestValue
    }
}
