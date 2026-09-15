import Foundation

public enum RadrootsBackgroundTransferValidation {
    public static func normalizedIdentifier(_ value: String) throws -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !trimmed.isEmpty else {
            throw RadrootsBackgroundTransferError.invalidRequest
        }
        guard trimmed.count <= 128 else {
            throw RadrootsBackgroundTransferError.invalidRequest
        }
        guard
            trimmed.range(of: "^[a-z0-9][a-z0-9._-]*[a-z0-9]$|^[a-z0-9]$", options: .regularExpression)
            != nil
        else {
            throw RadrootsBackgroundTransferError.invalidRequest
        }
        guard !trimmed.contains("..") else {
            throw RadrootsBackgroundTransferError.invalidRequest
        }
        return trimmed
    }

    public static func validate(
        remoteURL: URL, method: RadrootsBackgroundTransferMethod,
        operation: RadrootsBackgroundTransferOperation, headers: [String: String],
        metadata: [String: String], networkPolicy: RadrootsBackgroundTransferNetworkPolicy,
        responsePolicy: RadrootsBackgroundTransferResponsePolicy, expectedSourceSHA256: String?,
        maximumTransferBytes: UInt64
    ) throws {
        try validate(remoteURL: remoteURL, networkPolicy: networkPolicy)
        try validate(method: method, operation: operation)
        try validate(headers: headers)
        try validate(metadata: metadata)
        guard maximumTransferBytes > 0,
              maximumTransferBytes <= RadrootsBackgroundTransferRequest.absoluteMaximumTransferBytes
        else {
            throw RadrootsBackgroundTransferError.invalidRequest
        }
        if case .download = operation, responsePolicy != .discard {
            throw RadrootsBackgroundTransferError.invalidRequest
        }
        if let expectedSourceSHA256 {
            guard case .upload = operation,
                  expectedSourceSHA256.range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil
            else {
                throw RadrootsBackgroundTransferError.invalidRequest
            }
        }
        if case let .upload(.stagedBlob(blob)) = operation,
           UInt64(blob.sizeBytes) > maximumTransferBytes {
            throw RadrootsBackgroundTransferError.invalidRequest
        }
    }

    private static func validate(
        remoteURL: URL, networkPolicy: RadrootsBackgroundTransferNetworkPolicy
    ) throws {
        try RadrootsNativeDestinationPolicy.validate(remoteURL, policy: networkPolicy)
    }

    private static func validate(
        method: RadrootsBackgroundTransferMethod, operation: RadrootsBackgroundTransferOperation
    ) throws {
        switch operation {
        case let .download(destination):
            guard method == .get else {
                throw RadrootsBackgroundTransferError.invalidRequest
            }
            guard case .file = destination else {
                throw RadrootsBackgroundTransferError.invalidRequest
            }
            try validateLocalFile(destination)
        case let .upload(source):
            guard method == .post || method == .put else {
                throw RadrootsBackgroundTransferError.invalidRequest
            }
            try validateLocalFile(source)
        }
    }

    static func validateLocalFile(_ localFile: RadrootsBackgroundTransferLocalFile) throws {
        switch localFile {
        case let .file(reference):
            let path = reference.relativePath.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !path.isEmpty, !NSString(string: path).isAbsolutePath,
                  !path.split(separator: "/", omittingEmptySubsequences: false).contains(where: { $0 == ".." })
            else {
                throw RadrootsBackgroundTransferError.invalidRequest
            }
        case let .stagedBlob(blob):
            guard
                (try? RadrootsStagedBlobReference(
                    blobID: blob.blobID, sizeBytes: blob.sizeBytes, mediaType: blob.mediaType,
                    filenameHint: blob.filenameHint
                )) != nil
            else {
                throw RadrootsBackgroundTransferError.invalidRequest
            }
        }
    }

    private static func validate(headers: [String: String]) throws {
        guard headers.count <= 32 else {
            throw RadrootsBackgroundTransferError.invalidRequest
        }
        for (key, value) in headers {
            try validateSafeText(key, field: "background transfer header name", maximumLength: 80)
            guard key.range(of: "^[!#$%&'*+.^_`|~0-9A-Za-z-]+$", options: .regularExpression) != nil,
                  !["connection", "content-length", "host", "transfer-encoding"].contains(key.lowercased())
            else {
                throw RadrootsBackgroundTransferError.invalidRequest
            }
            try validateSafeText(value, field: "background transfer header value", maximumLength: 8192)
        }
    }

    private static func validate(metadata: [String: String]) throws {
        guard metadata.count <= 32 else {
            throw RadrootsBackgroundTransferError.invalidRequest
        }
        for (key, value) in metadata {
            try validateSafeText(key, field: "background transfer metadata key", maximumLength: 80)
            try validateSafeText(value, field: "background transfer metadata value", maximumLength: 500)
            let unsafeKey = key.lowercased()
            guard
                !["auth", "token", "secret", "credential", "cookie", "header", "path", "url"].contains(
                    where: { unsafeKey.contains($0) }
                )
            else {
                throw RadrootsBackgroundTransferError.invalidRequest
            }
        }
    }

    static func normalizedMediaType(_ value: String) throws -> String {
        let normalized =
            value.split(separator: ";", maxSplits: 1).first?.trimmingCharacters(
                in: .whitespacesAndNewlines
            ).lowercased() ?? ""
        guard
            normalized.range(of: "^[a-z0-9!#$&^_.+-]+/[a-z0-9!#$&^_.+-]+$", options: .regularExpression)
            != nil,
            normalized.utf8.count <= 127
        else {
            throw RadrootsBackgroundTransferError.invalidRequest
        }
        return normalized
    }

    static func validate(
        response: RadrootsBackgroundTransferResponse, policy: RadrootsBackgroundTransferResponsePolicy
    ) throws {
        guard (200 ... 299).contains(response.statusCode) else {
            throw RadrootsBackgroundTransferError.invalidRequest
        }
        if policy.maximumBodyBytes == 0 {
            guard response.body == nil, response.mediaType == nil else {
                throw RadrootsBackgroundTransferError.invalidRequest
            }
            return
        }
        guard let body = response.body, body.count <= policy.maximumBodyBytes,
              let mediaType = response.mediaType,
              policy.acceptedMediaTypes.contains(mediaType)
        else {
            throw RadrootsBackgroundTransferError.invalidRequest
        }
    }

    private static func validateSafeText(_ value: String, field _: String, maximumLength: Int) throws {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw RadrootsBackgroundTransferError.invalidRequest
        }
        guard trimmed.count <= maximumLength else {
            throw RadrootsBackgroundTransferError.invalidRequest
        }
        guard doesNotContainControlCharacters(trimmed) else {
            throw RadrootsBackgroundTransferError.invalidRequest
        }
    }

    private static func doesNotContainControlCharacters(_ value: String) -> Bool {
        value.unicodeScalars.allSatisfy { !CharacterSet.controlCharacters.contains($0) }
    }
}
