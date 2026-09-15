import Foundation

enum RadrootsStagedBackgroundDownloadResult: Sendable, Equatable {
    case file(URL)
    case failure
}

struct RadrootsBackgroundHTTPResult: Sendable, Equatable {
    let statusCode: Int?
    let mediaType: String?
    let body: Data?
    let contentEncoding: String?
    let bodyExceeded: Bool
    let mediaTypeWasMalformed: Bool
    let destinationMismatch: Bool
    let headerFailure: RadrootsBackgroundTransferFailure?

    init(
        statusCode: Int?, mediaType: String?, body: Data?, contentEncoding: String? = nil,
        bodyExceeded: Bool,
        mediaTypeWasMalformed: Bool = false, destinationMismatch: Bool = false,
        headerFailure: RadrootsBackgroundTransferFailure? = nil
    ) {
        self.statusCode = statusCode
        self.mediaType = mediaType
        self.body = body
        self.contentEncoding = contentEncoding
        self.bodyExceeded = bodyExceeded
        self.mediaTypeWasMalformed = mediaTypeWasMalformed
        self.destinationMismatch = destinationMismatch
        self.headerFailure = headerFailure
    }
}

struct RadrootsBackgroundURLTaskDescriptor: Sendable, Equatable {
    private static let prefix = "radroots-transfer-v1"

    let identifier: RadrootsBackgroundTransferIdentifier
    let maximumTransferBytes: UInt64
    let maximumResponseBodyBytes: Int
    let executionID: UUID?

    init(request: RadrootsBackgroundTransferRequest, executionID: UUID? = nil) {
        identifier = request.identifier
        maximumTransferBytes = request.maximumTransferBytes
        maximumResponseBodyBytes = request.responsePolicy.maximumBodyBytes
        self.executionID = executionID
    }

    init?(taskDescription: String?) {
        guard let taskDescription else { return nil }
        let components = taskDescription.split(separator: "|", omittingEmptySubsequences: false)
        if components.count == 5, components[0] == "radroots-transfer-v2",
           let executionID = UUID(uuidString: String(components[4])),
           let previous = Self(taskDescription: ([Self.prefix] + components[1 ... 3].map(String.init))
               .joined(separator: "|")) {
            identifier = previous.identifier
            maximumTransferBytes = previous.maximumTransferBytes
            maximumResponseBodyBytes = previous.maximumResponseBodyBytes
            self.executionID = executionID
            return
        }
        if components.count == 4,
           components[0] == Substring(Self.prefix),
           let identifier = try? RadrootsBackgroundTransferIdentifier(String(components[1])),
           let maximumTransferBytes = UInt64(components[2]),
           let maximumResponseBodyBytes = Int(components[3]),
           maximumTransferBytes > 0,
           maximumTransferBytes <= RadrootsBackgroundTransferRequest.absoluteMaximumTransferBytes,
           (0 ... 65536).contains(maximumResponseBodyBytes) {
            self.identifier = identifier
            self.maximumTransferBytes = maximumTransferBytes
            self.maximumResponseBodyBytes = maximumResponseBodyBytes
            executionID = nil
            return
        }
        guard let legacyIdentifier = try? RadrootsBackgroundTransferIdentifier(taskDescription) else {
            return nil
        }
        identifier = legacyIdentifier
        maximumTransferBytes = RadrootsBackgroundTransferRequest.defaultMaximumTransferBytes
        maximumResponseBodyBytes = 65536
        executionID = nil
    }

    var taskDescription: String {
        if let executionID {
            return "radroots-transfer-v2|\(identifier.rawValue)|\(maximumTransferBytes)|"
                + "\(maximumResponseBodyBytes)|\(executionID.uuidString.lowercased())"
        }
        return "\(Self.prefix)|\(identifier.rawValue)|\(maximumTransferBytes)|\(maximumResponseBodyBytes)"
    }
}

extension RadrootsBackgroundTransferRequest {
    var isUpload: Bool {
        if case .upload = operation {
            return true
        }
        return false
    }
}

struct RadrootsTransferResponseError: Error {
    let failure: RadrootsBackgroundTransferFailure
}
