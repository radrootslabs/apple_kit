import CoreTransferable
import Foundation
import SwiftUI
import UniformTypeIdentifiers

public enum RadrootsDocumentPresentationAdapter {
    public static func contentTypes(for request: RadrootsDocumentImportRequest) -> [UTType] {
        let types = request.allowedContentKinds.map(contentType(for:))
        return types.isEmpty ? [.item] : types
    }

    public static func contentType(for kind: RadrootsDocumentContentKind) -> UTType {
        switch kind {
        case .json:
            .json
        case .plainText:
            .plainText
        case .url:
            .url
        case .file:
            .item
        case .stagedBlob:
            .data
        }
    }

    public static func contentType(forMediaType mediaType: String?) -> UTType {
        guard let mediaType, let contentType = UTType(mimeType: mediaType) else {
            return .data
        }
        return contentType
    }

    public static func importDestination(
        sourceURL: URL,
        scope: RadrootsFileScope,
        importID: String
    ) throws -> RadrootsFileReference {
        let filename = sourceURL.lastPathComponent.isEmpty ? "document" : sourceURL.lastPathComponent
        let normalizedFilename = try RadrootsDocumentInterchangeValidation.normalizedFilename(filename)
        let normalizedImportID = try RadrootsPreparedExportDocument.normalizedPreparedID(importID)
        return RadrootsFileReference(
            scope: scope,
            relativePath: "document_import/\(normalizedImportID)/\(normalizedFilename)"
        )
    }

    public static func transferItem(for request: RadrootsShareRequest) throws -> RadrootsShareTransferItem {
        try transferItem(for: request, fileAccess: nil)
    }

    public static func transferItem(
        for request: RadrootsShareRequest,
        fileAccess: any RadrootsFileAccess
    ) throws -> RadrootsShareTransferItem {
        let optionalFileAccess: (any RadrootsFileAccess)? = fileAccess
        return try transferItem(for: request, fileAccess: optionalFileAccess)
    }

    private static func transferItem(
        for request: RadrootsShareRequest,
        fileAccess: (any RadrootsFileAccess)?
    ) throws -> RadrootsShareTransferItem {
        for item in request.items {
            switch try item.normalized {
            case let .text(text):
                return try RadrootsShareTransferItem(text: text, subject: request.subject)
            case let .url(url):
                return try RadrootsShareTransferItem(url: url, subject: request.subject)
            case let .file(file, suggestedFilename, mediaType, sizeBytes):
                guard let fileAccess else {
                    continue
                }
                let export = try fileAccess.prepareExport(
                    RadrootsExportDocumentRequest(
                        source: .file(file),
                        suggestedFilename: shareFilename(
                            explicitFilename: suggestedFilename,
                            fallbackFilename: NSString(string: file.relativePath).lastPathComponent
                        ),
                        mediaType: mediaType,
                        sizeBytes: sizeBytes
                    )
                )
                return try RadrootsShareTransferItem(preparedExport: export, subject: request.subject)
            case let .stagedBlob(stagedBlob, suggestedFilename):
                guard let fileAccess else {
                    continue
                }
                let export = try fileAccess.prepareExport(
                    RadrootsExportDocumentRequest(
                        source: .stagedBlob(stagedBlob),
                        suggestedFilename: shareFilename(
                            explicitFilename: suggestedFilename,
                            fallbackFilename: stagedBlob.filenameHint ?? stagedBlob.blobID
                        ),
                        mediaType: stagedBlob.mediaType,
                        sizeBytes: UInt64(stagedBlob.sizeBytes)
                    )
                )
                return try RadrootsShareTransferItem(preparedExport: export, subject: request.subject)
            }
        }
        throw RadrootsDocumentInterchangeError.invalidRequest("share request does not contain a supported public share item")
    }

    private static func shareFilename(explicitFilename: String?, fallbackFilename: String) throws -> String {
        if let explicitFilename {
            return try RadrootsDocumentInterchangeValidation.normalizedFilename(explicitFilename)
        }
        let fallback = fallbackFilename.trimmingCharacters(in: .whitespacesAndNewlines)
        if fallback.isEmpty {
            return "radroots-share-item"
        }
        return try RadrootsDocumentInterchangeValidation.normalizedFilename(fallback)
    }
}

public struct RadrootsShareTransferItem: Transferable, Sendable, Equatable, Hashable {
    public enum Payload: Sendable, Equatable, Hashable {
        case text(String)
        case url(URL)
        case file(RadrootsPreparedExportDocument)
    }

    public let payload: Payload
    public let subject: String?

    public init(text: String, subject: String? = nil) throws {
        payload = try .text(RadrootsDocumentInterchangeValidation.normalizedPublicText(text, field: "share transfer text"))
        self.subject = try RadrootsDocumentInterchangeValidation.normalizedOptionalPublicText(
            subject,
            field: "share transfer subject"
        )
    }

    public init(url: URL, subject: String? = nil) throws {
        payload = try .url(RadrootsDocumentInterchangeValidation.normalizedPublicURL(url))
        self.subject = try RadrootsDocumentInterchangeValidation.normalizedOptionalPublicText(
            subject,
            field: "share transfer subject"
        )
    }

    public init(preparedExport: RadrootsPreparedExportDocument, subject: String? = nil) throws {
        payload = .file(preparedExport)
        self.subject = try RadrootsDocumentInterchangeValidation.normalizedOptionalPublicText(
            subject,
            field: "share transfer subject"
        )
    }

    public var text: String? {
        switch payload {
        case let .text(text):
            text
        case let .url(url):
            url.absoluteString
        case .file:
            nil
        }
    }

    public var url: URL? {
        guard case let .url(url) = payload else {
            return nil
        }
        return url
    }

    public var preparedExport: RadrootsPreparedExportDocument? {
        guard case let .file(preparedExport) = payload else {
            return nil
        }
        return preparedExport
    }

    public var transferText: String {
        switch payload {
        case let .text(text):
            text
        case let .url(url):
            url.absoluteString
        case let .file(preparedExport):
            preparedExport.suggestedFilename
        }
    }

    public static var transferRepresentation: some TransferRepresentation {
        ProxyRepresentation(exporting: \.transferText)
    }
}

public struct RadrootsPreparedExportFileDocument: FileDocument {
    public static var readableContentTypes: [UTType] {
        [.data]
    }

    public let fileURL: URL

    public init(preparedExport: RadrootsPreparedExportDocument) {
        fileURL = preparedExport.fileURL
    }

    public init(configuration _: ReadConfiguration) throws {
        throw RadrootsDocumentInterchangeError.invalidRequest("prepared export documents are write only")
    }

    public func fileWrapper(configuration _: WriteConfiguration) throws -> FileWrapper {
        try FileWrapper(url: fileURL, options: [])
    }
}

public struct RadrootsDocumentImportPresentationModifier: ViewModifier {
    @Binding private var request: RadrootsDocumentImportRequest?
    private let fileAccess: any RadrootsFileAccess
    private let onCompletion: (Result<RadrootsDocumentImportResult, Error>) -> Void

    public init(
        request: Binding<RadrootsDocumentImportRequest?>,
        fileAccess: any RadrootsFileAccess,
        onCompletion: @escaping (Result<RadrootsDocumentImportResult, Error>) -> Void
    ) {
        _request = request
        self.fileAccess = fileAccess
        self.onCompletion = onCompletion
    }

    public func body(content: Content) -> some View {
        content.fileImporter(
            isPresented: Binding(
                get: { request != nil },
                set: { isPresented in
                    if !isPresented {
                        request = nil
                    }
                }
            ),
            allowedContentTypes: request.map(RadrootsDocumentPresentationAdapter.contentTypes(for:)) ?? [.item],
            allowsMultipleSelection: request?.allowsMultipleSelection ?? false
        ) { result in
            handleImportResult(result)
        }
    }

    private func handleImportResult(_ result: Result<[URL], Error>) {
        guard let currentRequest = request else {
            return
        }
        request = nil
        do {
            let urls = try result.get()
            guard !urls.isEmpty else {
                throw RadrootsDocumentInterchangeError.userCancelled("document import was cancelled")
            }
            let documents = try urls.map { sourceURL in
                let destination = try RadrootsDocumentPresentationAdapter.importDestination(
                    sourceURL: sourceURL,
                    scope: currentRequest.destinationScope,
                    importID: UUID().uuidString.lowercased()
                )
                return try fileAccess.copyExternalFile(
                    sourceURL,
                    to: destination,
                    mediaType: nil,
                    suggestedFilename: sourceURL.lastPathComponent
                )
            }
            try onCompletion(.success(RadrootsDocumentImportResult(documents: documents)))
        } catch {
            onCompletion(.failure(error))
        }
    }
}

public struct RadrootsDocumentExportPresentationModifier: ViewModifier {
    @Binding private var preparedExport: RadrootsPreparedExportDocument?
    private let onCompletion: (Result<RadrootsExportDocumentResult, Error>) -> Void

    public init(
        preparedExport: Binding<RadrootsPreparedExportDocument?>,
        onCompletion: @escaping (Result<RadrootsExportDocumentResult, Error>) -> Void
    ) {
        _preparedExport = preparedExport
        self.onCompletion = onCompletion
    }

    public func body(content: Content) -> some View {
        content.fileExporter(
            isPresented: Binding(
                get: { preparedExport != nil },
                set: { isPresented in
                    if !isPresented {
                        preparedExport = nil
                    }
                }
            ),
            document: preparedExport.map(RadrootsPreparedExportFileDocument.init(preparedExport:)),
            contentType: RadrootsDocumentPresentationAdapter.contentType(forMediaType: preparedExport?.mediaType),
            defaultFilename: preparedExport?.suggestedFilename
        ) { result in
            handleExportResult(result)
        }
    }

    private func handleExportResult(_ result: Result<URL, Error>) {
        guard let currentExport = preparedExport else {
            return
        }
        preparedExport = nil
        do {
            let destinationURL = try result.get()
            try onCompletion(
                .success(
                    RadrootsExportDocumentResult(
                        exportedFilename: destinationURL.lastPathComponent.isEmpty
                            ? currentExport.suggestedFilename
                            : destinationURL.lastPathComponent,
                        mediaType: currentExport.mediaType,
                        sizeBytes: currentExport.sizeBytes
                    )
                )
            )
        } catch {
            onCompletion(.failure(error))
        }
    }
}

public struct RadrootsSharePresentationLink<Label: View>: View {
    private let transferItem: RadrootsShareTransferItem
    private let label: () -> Label

    public init(
        request: RadrootsShareRequest,
        @ViewBuilder label: @escaping () -> Label
    ) throws {
        transferItem = try RadrootsDocumentPresentationAdapter.transferItem(for: request)
        self.label = label
    }

    public init(
        request: RadrootsShareRequest,
        fileAccess: any RadrootsFileAccess,
        @ViewBuilder label: @escaping () -> Label
    ) throws {
        transferItem = try RadrootsDocumentPresentationAdapter.transferItem(
            for: request,
            fileAccess: fileAccess
        )
        self.label = label
    }

    public var body: some View {
        switch transferItem.payload {
        case let .text(text):
            ShareLink(
                item: text,
                subject: transferItem.subject.map(Text.init) ?? Text(""),
                message: Text(text),
                label: label
            )
        case let .url(url):
            ShareLink(
                item: url,
                subject: transferItem.subject.map(Text.init) ?? Text(""),
                message: Text(url.absoluteString),
                label: label
            )
        case let .file(preparedExport):
            ShareLink(
                item: preparedExport.fileURL,
                subject: transferItem.subject.map(Text.init) ?? Text(""),
                message: Text(preparedExport.suggestedFilename),
                label: label
            )
        }
    }
}

public extension View {
    func radrootsDocumentImporter(
        request: Binding<RadrootsDocumentImportRequest?>,
        fileAccess: any RadrootsFileAccess,
        onCompletion: @escaping (Result<RadrootsDocumentImportResult, Error>) -> Void
    ) -> some View {
        modifier(
            RadrootsDocumentImportPresentationModifier(
                request: request,
                fileAccess: fileAccess,
                onCompletion: onCompletion
            )
        )
    }

    func radrootsDocumentExporter(
        preparedExport: Binding<RadrootsPreparedExportDocument?>,
        onCompletion: @escaping (Result<RadrootsExportDocumentResult, Error>) -> Void
    ) -> some View {
        modifier(
            RadrootsDocumentExportPresentationModifier(
                preparedExport: preparedExport,
                onCompletion: onCompletion
            )
        )
    }
}
