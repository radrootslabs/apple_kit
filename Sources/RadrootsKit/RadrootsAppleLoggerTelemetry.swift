import Foundation
import OSLog

public struct RadrootsAppleTelemetryLogRecord: Sendable, Equatable {
    public let subsystem: String
    public let category: String
    public let level: RadrootsTelemetryLevel
    public let renderedMessage: String

    public init(
        subsystem: String,
        category: String,
        level: RadrootsTelemetryLevel,
        renderedMessage: String
    ) {
        self.subsystem = subsystem
        self.category = category
        self.level = level
        self.renderedMessage = renderedMessage
    }
}

public struct RadrootsAppleLoggerTelemetryAdapters: Sendable {
    public let emit: @Sendable (RadrootsAppleTelemetryLogRecord) -> Void

    public init(emit: @escaping @Sendable (RadrootsAppleTelemetryLogRecord) -> Void) {
        self.emit = emit
    }

    public static let live = Self { record in
        let logger = Logger(subsystem: record.subsystem, category: record.category)
        logger.log(level: record.osLogType, "\(record.renderedMessage, privacy: .public)")
    }
}

public final class RadrootsAppleLoggerTelemetry: RadrootsTelemetry, Sendable {
    private let subsystem: String
    private let adapters: RadrootsAppleLoggerTelemetryAdapters
    private let redactionPolicy: RadrootsTelemetryRedactionPolicy
    private let maximumRenderedMessageLength: Int

    public init(
        subsystem: String,
        adapters: RadrootsAppleLoggerTelemetryAdapters = .live,
        redactionPolicy: RadrootsTelemetryRedactionPolicy = .default,
        maximumRenderedMessageLength: Int = 1000
    ) {
        self.subsystem = Self.normalizedSubsystem(subsystem)
        self.adapters = adapters
        self.redactionPolicy = redactionPolicy
        self.maximumRenderedMessageLength = max(160, maximumRenderedMessageLength)
    }

    public func record(_ event: RadrootsTelemetryEvent) async {
        let redactedEvent = redactionPolicy.redacted(event)
        let renderedMessage = Self.renderedMessage(
            for: redactedEvent,
            maximumLength: maximumRenderedMessageLength
        )
        adapters.emit(
            RadrootsAppleTelemetryLogRecord(
                subsystem: subsystem,
                category: Self.normalizedCategory(redactedEvent.category),
                level: redactedEvent.level,
                renderedMessage: renderedMessage
            )
        )
    }

    public static func normalizedSubsystem(_ value: String) -> String {
        normalizedLogIdentifier(
            value,
            fallback: "org.radroots.apple_kit",
            maximumLength: 120
        )
    }

    public static func normalizedCategory(_ value: String) -> String {
        normalizedLogIdentifier(
            value,
            fallback: "app",
            maximumLength: 80
        )
    }

    public static func renderedMessage(
        for event: RadrootsTelemetryEvent,
        maximumLength: Int = 1000
    ) -> String {
        let payload = RadrootsAppleTelemetryPayload(
            category: event.category,
            event: event.name,
            fields: Dictionary(uniqueKeysWithValues: event.fields.map { field in
                (field.key, field.value.renderedValue)
            }),
            level: event.level.rawValue,
            message: event.message,
            occurredAtUnixMilliseconds: Int64(event.occurredAt.timeIntervalSince1970 * 1000)
        )
        let rendered: String
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            let data = try encoder.encode(payload)
            rendered = String(decoding: data, as: UTF8.self)
        } catch {
            rendered = "{\"event\":\"\(event.name)\",\"level\":\"\(event.level.rawValue)\"}"
        }
        let boundedLength = max(160, maximumLength)
        guard rendered.count > boundedLength else {
            return rendered
        }
        return String(rendered.prefix(boundedLength))
    }

    private static func normalizedLogIdentifier(
        _ value: String,
        fallback: String,
        maximumLength: Int
    ) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return fallback
        }
        var normalized = ""
        for scalar in trimmed.unicodeScalars {
            if CharacterSet.alphanumerics.contains(scalar) || scalar == "." || scalar == "_" || scalar == "-" {
                normalized.append(String(scalar))
            } else {
                normalized.append("_")
            }
        }
        let collapsed = normalized.replacingOccurrences(
            of: "_+",
            with: "_",
            options: .regularExpression
        )
        let trimmedSeparators = collapsed.trimmingCharacters(in: CharacterSet(charactersIn: "._-"))
        guard !trimmedSeparators.isEmpty else {
            return fallback
        }
        return String(trimmedSeparators.prefix(maximumLength))
    }
}

private struct RadrootsAppleTelemetryPayload: Encodable {
    let category: String
    let event: String
    let fields: [String: String]
    let level: String
    let message: String?
    let occurredAtUnixMilliseconds: Int64

    enum CodingKeys: String, CodingKey {
        case category
        case event
        case fields
        case level
        case message
        case occurredAtUnixMilliseconds = "occurred_at_unix_ms"
    }
}

extension RadrootsAppleTelemetryLogRecord {
    var osLogType: OSLogType {
        switch level {
        case .trace, .debug:
            .debug
        case .info:
            .info
        case .notice, .warning:
            .default
        case .error:
            .error
        case .critical:
            .fault
        }
    }
}
