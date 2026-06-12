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
            throw RadrootsAppLocalStateResetError.invalidRequest("app identifier cannot be empty")
        }
        let root = try fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        ).appendingPathComponent(trimmed, isDirectory: true)
        if fileManager.fileExists(atPath: root.path) {
            try fileManager.removeItem(at: root)
        }
    }

    public static func clearKeychainService(_ serviceName: String) throws {
        let trimmed = serviceName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw RadrootsAppLocalStateResetError.invalidRequest("keychain service name cannot be empty")
        }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: trimmed
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw RadrootsAppLocalStateResetError.keychainStatus(status, "keychain service reset failed")
        }
    }
}

public enum RadrootsAppLocalStateResetError: Error, Equatable, Sendable {
    case invalidRequest(String)
    case keychainStatus(Int32, String)
}
