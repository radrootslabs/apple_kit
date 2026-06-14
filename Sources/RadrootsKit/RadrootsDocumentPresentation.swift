import Foundation
import SwiftUI
import UniformTypeIdentifiers
import CoreTransferable

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
        for item in request.items {
            switch try item.normalized {
            case .text(let text):
                return try RadrootsShareTransferItem(text: text, subject: request.subject)
            case .url(let url):
                return try RadrootsShareTransferItem(text: url.absoluteString, subject: request.subject)
            case .file, .stagedBlob:
                continue
            }
        }
        throw RadrootsDocumentInterchangeError.invalidRequest("share request does not contain a public text or url item")
    }
}

public struct RadrootsShareTransferItem: Transferable, Sendable, Equatable, Hashable {
    public let text: String
    public let subject: String?

    public init(text: String, subject: String? = nil) throws {
        self.text = try RadrootsDocumentInterchangeValidation.normalizedPublicText(text, field: "share transfer text")
        self.subject = try RadrootsDocumentInterchangeValidation.normalizedOptionalPublicText(
            subject,
            field: "share transfer subject"
        )
    }

    public static var transferRepresentation: some TransferRepresentation {
        ProxyRepresentation(exporting: \.text)
    }
}

public struct RadrootsPreparedExportFileDocument: FileDocument {
    public static var readableContentTypes: [UTType] {
        [.data]
    }

    public let fileURL: URL

    public init(preparedExport: RadrootsPreparedExportDocument) {
        self.fileURL = preparedExport.fileURL
    }

    public init(configuration: ReadConfiguration) throws {
        throw RadrootsDocumentInterchangeError.invalidRequest("prepared export documents are write only")
    }

    public func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
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
        self._request = request
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
            onCompletion(.success(try RadrootsDocumentImportResult(documents: documents)))
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
        self._preparedExport = preparedExport
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
            onCompletion(
                .success(
                    try RadrootsExportDocumentResult(
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
        self.transferItem = try RadrootsDocumentPresentationAdapter.transferItem(for: request)
        self.label = label
    }

    public var body: some View {
        ShareLink(
            item: transferItem.text,
            subject: transferItem.subject.map(Text.init) ?? Text(""),
            message: Text(transferItem.text),
            label: label
        )
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
