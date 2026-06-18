import Foundation

public enum RadrootsDocumentContentKind: String, Sendable, Equatable, Hashable, CaseIterable {
    case json
    case plainText
    case url
    case file
    case stagedBlob
}

public enum RadrootsDocumentInterchangeError: Error, Equatable, Sendable {
    case invalidRequest(String)
    case notFound(String)
    case userCancelled(String)
    case permissionDenied(String)
    case transientFailure(String)
    case permanentFailure(String)
}

extension RadrootsDocumentInterchangeError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .invalidRequest(let message):
            message
        case .notFound(let message):
            message
        case .userCancelled(let message):
            message
        case .permissionDenied(let message):
            message
        case .transientFailure(let message):
            message
        case .permanentFailure(let message):
            message
        }
    }
}

public struct RadrootsDocumentImportRequest: Sendable, Equatable, Hashable {
    public let allowedContentKinds: [RadrootsDocumentContentKind]
    public let allowsMultipleSelection: Bool
    public let destinationScope: RadrootsFileScope

    public init(
        allowedContentKinds: [RadrootsDocumentContentKind],
        allowsMultipleSelection: Bool = false,
        destinationScope: RadrootsFileScope = .temporary
    ) throws {
        let normalizedKinds = try Self.normalizedContentKinds(allowedContentKinds)
        self.allowedContentKinds = normalizedKinds
        self.allowsMultipleSelection = allowsMultipleSelection
        self.destinationScope = destinationScope
    }

    public static func normalizedContentKinds(
        _ allowedContentKinds: [RadrootsDocumentContentKind]
    ) throws -> [RadrootsDocumentContentKind] {
        var seen = Set<RadrootsDocumentContentKind>()
        let normalized = allowedContentKinds.filter { kind in
            if seen.contains(kind) {
                return false
            }
            seen.insert(kind)
            return true
        }
        guard !normalized.isEmpty else {
            throw RadrootsDocumentInterchangeError.invalidRequest("document import must allow at least one content kind")
        }
        return normalized
    }
}

public struct RadrootsImportedDocument: Sendable, Equatable, Hashable {
    public let file: RadrootsFileReference
    public let originalURL: URL?
    public let suggestedFilename: String
    public let mediaType: String?
    public let sizeBytes: UInt64

    public init(
        file: RadrootsFileReference,
        originalURL: URL?,
        suggestedFilename: String,
        mediaType: String?,
        sizeBytes: UInt64
    ) throws {
        self.file = file
        self.originalURL = try Self.normalizedOriginalURL(originalURL)
        self.suggestedFilename = try RadrootsDocumentInterchangeValidation.normalizedFilename(suggestedFilename)
        self.mediaType = try RadrootsDocumentInterchangeValidation.normalizedMediaType(mediaType)
        self.sizeBytes = sizeBytes
    }

    public static func normalizedOriginalURL(_ originalURL: URL?) throws -> URL? {
        guard let originalURL else {
            return nil
        }
        guard originalURL.isFileURL else {
            throw RadrootsDocumentInterchangeError.invalidRequest("imported document original url must be a file url")
        }
        return originalURL.standardizedFileURL
    }
}

public struct RadrootsDocumentImportResult: Sendable, Equatable, Hashable {
    public let documents: [RadrootsImportedDocument]

    public init(documents: [RadrootsImportedDocument]) throws {
        guard !documents.isEmpty else {
            throw RadrootsDocumentInterchangeError.invalidRequest("document import result cannot be empty")
        }
        self.documents = documents
    }
}

public enum RadrootsShareItem: Sendable, Equatable, Hashable {
    case text(String)
    case url(URL)
    case file(RadrootsFileReference, suggestedFilename: String?, mediaType: String?, sizeBytes: UInt64?)
    case stagedBlob(RadrootsStagedBlobReference, suggestedFilename: String?)

    public static func validatedText(_ value: String) throws -> Self {
        .text(try RadrootsDocumentInterchangeValidation.normalizedPublicText(value, field: "share text"))
    }

    public static func validatedURL(_ value: URL) throws -> Self {
        .url(try RadrootsDocumentInterchangeValidation.normalizedPublicURL(value))
    }

    public static func validatedFile(
        _ file: RadrootsFileReference,
        suggestedFilename: String? = nil,
        mediaType: String? = nil,
        sizeBytes: UInt64? = nil
    ) throws -> Self {
        let normalizedFile = try RadrootsDocumentInterchangeValidation.normalizedScopedFileReference(file)
        return .file(
            normalizedFile,
            suggestedFilename: try RadrootsDocumentInterchangeValidation.normalizedOptionalFilename(suggestedFilename),
            mediaType: try RadrootsDocumentInterchangeValidation.normalizedMediaType(mediaType),
            sizeBytes: sizeBytes
        )
    }

    public static func validatedStagedBlob(
        _ stagedBlob: RadrootsStagedBlobReference,
        suggestedFilename: String? = nil
    ) throws -> Self {
        try RadrootsDocumentInterchangeValidation.validateNoSecretMaterial(
            stagedBlob.filenameHint,
            field: "staged blob filename hint"
        )
        return .stagedBlob(
            stagedBlob,
            suggestedFilename: try RadrootsDocumentInterchangeValidation.normalizedOptionalFilename(suggestedFilename)
        )
    }

    public var normalized: Self {
        get throws {
            switch self {
            case .text(let text):
                try Self.validatedText(text)
            case .url(let url):
                try Self.validatedURL(url)
            case .file(let file, let suggestedFilename, let mediaType, let sizeBytes):
                try Self.validatedFile(file, suggestedFilename: suggestedFilename, mediaType: mediaType, sizeBytes: sizeBytes)
            case .stagedBlob(let stagedBlob, let suggestedFilename):
                try Self.validatedStagedBlob(stagedBlob, suggestedFilename: suggestedFilename)
            }
        }
    }
}

public struct RadrootsShareRequest: Sendable, Equatable, Hashable {
    public let items: [RadrootsShareItem]
    public let subject: String?

    public init(items: [RadrootsShareItem], subject: String? = nil) throws {
        let normalizedItems = try items.map { try $0.normalized }
        guard !normalizedItems.isEmpty else {
            throw RadrootsDocumentInterchangeError.invalidRequest("share request must contain at least one item")
        }
        self.items = normalizedItems
        self.subject = try RadrootsDocumentInterchangeValidation.normalizedOptionalPublicText(subject, field: "share subject")
    }
}

public struct RadrootsShareResult: Sendable, Equatable, Hashable {
    public let completed: Bool

    public init(completed: Bool) {
        self.completed = completed
    }
}

public enum RadrootsExportDocumentSource: Sendable, Equatable, Hashable {
    case inlineData(Data)
    case file(RadrootsFileReference)
    case stagedBlob(RadrootsStagedBlobReference)
}

public struct RadrootsExportDocumentRequest: Sendable, Equatable, Hashable {
    public let source: RadrootsExportDocumentSource
    public let suggestedFilename: String
    public let mediaType: String?
    public let sizeBytes: UInt64?

    public init(
        source: RadrootsExportDocumentSource,
        suggestedFilename: String,
        mediaType: String?,
        sizeBytes: UInt64? = nil
    ) throws {
        self.source = source
        self.suggestedFilename = try RadrootsDocumentInterchangeValidation.normalizedFilename(suggestedFilename)
        self.mediaType = try RadrootsDocumentInterchangeValidation.normalizedMediaType(mediaType)
        self.sizeBytes = try Self.normalizedSizeBytes(source: source, requestedSizeBytes: sizeBytes)
    }

    public static func normalizedSizeBytes(
        source: RadrootsExportDocumentSource,
        requestedSizeBytes: UInt64?
    ) throws -> UInt64? {
        switch source {
        case .inlineData(let data):
            let actualSize = UInt64(data.count)
            if let requestedSizeBytes, requestedSizeBytes != actualSize {
                throw RadrootsDocumentInterchangeError.invalidRequest("inline export byte count does not match data size")
            }
            return actualSize
        case .file:
            return requestedSizeBytes
        case .stagedBlob(let stagedBlob):
            let actualSize = UInt64(stagedBlob.sizeBytes)
            if let requestedSizeBytes, requestedSizeBytes != actualSize {
                throw RadrootsDocumentInterchangeError.invalidRequest("staged blob export byte count does not match reference size")
            }
            return actualSize
        }
    }
}

public struct RadrootsExportDocumentResult: Sendable, Equatable, Hashable {
    public let exportedFilename: String
    public let mediaType: String?
    public let sizeBytes: UInt64?

    public init(
        exportedFilename: String,
        mediaType: String?,
        sizeBytes: UInt64?
    ) throws {
        self.exportedFilename = try RadrootsDocumentInterchangeValidation.normalizedFilename(exportedFilename)
        self.mediaType = try RadrootsDocumentInterchangeValidation.normalizedMediaType(mediaType)
        self.sizeBytes = sizeBytes
    }
}

public struct RadrootsPreparedExportDocument: Sendable, Equatable, Hashable {
    public let preparedID: String
    public let fileURL: URL
    public let suggestedFilename: String
    public let mediaType: String?
    public let sizeBytes: UInt64?

    public init(
        preparedID: String,
        fileURL: URL,
        suggestedFilename: String,
        mediaType: String?,
        sizeBytes: UInt64?
    ) throws {
        self.preparedID = try Self.normalizedPreparedID(preparedID)
        self.fileURL = try Self.normalizedFileURL(fileURL)
        self.suggestedFilename = try RadrootsDocumentInterchangeValidation.normalizedFilename(suggestedFilename)
        self.mediaType = try RadrootsDocumentInterchangeValidation.normalizedMediaType(mediaType)
        self.sizeBytes = sizeBytes
    }

    public static func normalizedPreparedID(_ preparedID: String) throws -> String {
        let trimmed = preparedID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw RadrootsDocumentInterchangeError.invalidRequest("prepared export id cannot be empty")
        }
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_")
        guard trimmed.rangeOfCharacter(from: allowed.inverted) == nil else {
            throw RadrootsDocumentInterchangeError.invalidRequest("prepared export id contains invalid characters")
        }
        return trimmed
    }

    public static func normalizedFileURL(_ fileURL: URL) throws -> URL {
        guard fileURL.isFileURL else {
            throw RadrootsDocumentInterchangeError.invalidRequest("prepared export url must be a file url")
        }
        return fileURL.standardizedFileURL
    }
}

public enum RadrootsDocumentInterchangeValidation {
    public static func normalizedFilename(_ filename: String) throws -> String {
        let trimmed = filename.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw RadrootsDocumentInterchangeError.invalidRequest("document filename cannot be empty")
        }
        guard trimmed != "." && trimmed != ".." else {
            throw RadrootsDocumentInterchangeError.invalidRequest("document filename cannot be a path segment")
        }
        guard !NSString(string: trimmed).isAbsolutePath else {
            throw RadrootsDocumentInterchangeError.invalidRequest("document filename cannot be absolute")
        }
        guard !trimmed.contains("/") && !trimmed.contains("\\") && !trimmed.contains("\0") else {
            throw RadrootsDocumentInterchangeError.invalidRequest("document filename cannot contain path separators")
        }
        guard trimmed.rangeOfCharacter(from: .controlCharacters) == nil else {
            throw RadrootsDocumentInterchangeError.invalidRequest("document filename cannot contain control characters")
        }
        guard trimmed.utf8.count <= 255 else {
            throw RadrootsDocumentInterchangeError.invalidRequest("document filename is too long")
        }
        try validateNoSecretMaterial(trimmed, field: "document filename")
        return trimmed
    }

    public static func normalizedOptionalFilename(_ filename: String?) throws -> String? {
        guard let filename else {
            return nil
        }
        return try normalizedFilename(filename)
    }

    public static func normalizedMediaType(_ mediaType: String?) throws -> String? {
        guard let mediaType else {
            return nil
        }
        let trimmed = mediaType.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw RadrootsDocumentInterchangeError.invalidRequest("document media type cannot be empty")
        }
        guard trimmed.rangeOfCharacter(from: .whitespacesAndNewlines.union(.controlCharacters)) == nil else {
            throw RadrootsDocumentInterchangeError.invalidRequest("document media type cannot contain whitespace")
        }
        let parts = trimmed.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 2, parts.allSatisfy({ !$0.isEmpty }) else {
            throw RadrootsDocumentInterchangeError.invalidRequest("document media type must be type/subtype")
        }
        return trimmed.lowercased()
    }

    public static func normalizedPublicText(_ text: String, field: String) throws -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw RadrootsDocumentInterchangeError.invalidRequest("\(field) cannot be empty")
        }
        try validateNoSecretMaterial(trimmed, field: field)
        return trimmed
    }

    public static func normalizedOptionalPublicText(_ text: String?, field: String) throws -> String? {
        guard let text else {
            return nil
        }
        return try normalizedPublicText(text, field: field)
    }

    public static func normalizedPublicURL(_ url: URL) throws -> URL {
        guard let scheme = url.scheme?.lowercased(), scheme == "https" || scheme == "http" else {
            throw RadrootsDocumentInterchangeError.invalidRequest("share url must be http or https")
        }
        guard url.host != nil else {
            throw RadrootsDocumentInterchangeError.invalidRequest("share url must include a host")
        }
        try validateNoSecretMaterial(url.absoluteString, field: "share url")
        return url
    }

    public static func normalizedScopedFileReference(_ file: RadrootsFileReference) throws -> RadrootsFileReference {
        let trimmed = file.relativePath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw RadrootsDocumentInterchangeError.invalidRequest("share file path cannot be empty")
        }
        guard !NSString(string: trimmed).isAbsolutePath else {
            throw RadrootsDocumentInterchangeError.invalidRequest("share file path cannot be absolute")
        }
        guard !trimmed.contains("\\") && !trimmed.contains("\0") else {
            throw RadrootsDocumentInterchangeError.invalidRequest("share file path cannot contain unsafe separators")
        }
        guard trimmed.rangeOfCharacter(from: .controlCharacters) == nil else {
            throw RadrootsDocumentInterchangeError.invalidRequest("share file path cannot contain control characters")
        }
        let components = trimmed.split(separator: "/", omittingEmptySubsequences: false)
        guard components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else {
            throw RadrootsDocumentInterchangeError.invalidRequest("share file path cannot contain empty or parent segments")
        }
        try validateNoSecretMaterial(trimmed, field: "share file path")
        return RadrootsFileReference(scope: file.scope, relativePath: trimmed)
    }

    public static func validateNoSecretMaterial(_ value: String?, field: String) throws {
        guard let value else {
            return
        }
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !normalized.isEmpty else {
            return
        }
        let unsafeFragments = [
            "nsec",
            "secret_hex",
            "selected_secret",
            "private_key",
            "private key",
            "secret_key",
            "secret key"
        ]
        guard !unsafeFragments.contains(where: normalized.contains) else {
            throw RadrootsDocumentInterchangeError.invalidRequest("\(field) cannot contain secret material")
        }
    }
}
