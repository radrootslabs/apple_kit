import Foundation
import Security

public struct RadrootsAppLocalStateResetRequest: Sendable, Equatable {
    public let appIdentifier: String
    public let keychainServiceNames: [String]

    public init(appIdentifier: String, keychainServiceNames: [String] = []) {
        self.appIdentifier = appIdentifier
        self.keychainServiceNames = keychainServiceNames
    }
}

public enum RadrootsAppLocalStateReset {
    public static func reset(_ request: RadrootsAppLocalStateResetRequest) throws {
        try clearApplicationSupport(appIdentifier: request.appIdentifier)
        for serviceName in request.keychainServiceNames {
            try clearKeychainService(serviceName)
        }
    }

    public static func clearApplicationSupport(
        appIdentifier: String,
        fileManager: FileManager = .default
    ) throws {
        let trimmed = appIdentifier.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw RadrootsAppLocalStateResetError.invalidRequest
        }
        do {
        let root = try fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        ).appendingPathComponent(trimmed, isDirectory: true)
        if fileManager.fileExists(atPath: root.path) {
            try fileManager.removeItem(at: root)
        }
        } catch let error as RadrootsAppLocalStateResetError {
            throw error
        } catch {
            throw RadrootsAppLocalStateResetError.fileSystemFailure
        }
    }

    public static func clearKeychainService(_ serviceName: String) throws {
        let trimmed = serviceName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw RadrootsAppLocalStateResetError.invalidRequest
        }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: trimmed,
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw RadrootsAppLocalStateResetError.keychainFailure
        }
    }
}

public enum RadrootsAppLocalStateResetError: Error, Equatable, Sendable {
    case invalidRequest
    case fileSystemFailure
    case keychainFailure
}

extension RadrootsAppLocalStateResetError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .invalidRequest: "The local-state reset request is invalid."
        case .fileSystemFailure: "The local application state could not be reset."
        case .keychainFailure: "The secure local state could not be reset."
        }
    }
}
