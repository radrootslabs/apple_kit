import Foundation

public struct RadrootsUITestLaunchConfiguration: Sendable, Equatable {
    public let environment: [String: String]
    public let arguments: [String]

    public init(environment: [String: String], arguments: [String]) {
        self.environment = environment
        self.arguments = arguments
    }

    public static func deterministic(
        environment: [String: String] = [:],
        arguments: [String] = [],
        language: String = "en",
        locale: String = "en_US_POSIX"
    ) -> Self {
        Self(
            environment: environment,
            arguments: arguments + [
                "-AppleLanguages",
                "(\(language))",
                "-AppleLocale",
                locale
            ]
        )
    }

    public func mergedEnvironment(over base: [String: String]) -> [String: String] {
        var merged = base
        for (key, value) in environment {
            merged[key] = value
        }
        return merged
    }
}
