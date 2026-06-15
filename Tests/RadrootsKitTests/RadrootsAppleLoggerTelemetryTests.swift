import Foundation
import Testing
@testable import RadrootsKit

@Test func appleLoggerTelemetryEmitsRedactedBoundedRecords() async throws {
    let probe = RadrootsAppleLoggerTelemetryProbe()
    let telemetry = RadrootsAppleLoggerTelemetry(
        subsystem: " org.radroots.field ios ",
        adapters: RadrootsAppleLoggerTelemetryAdapters(emit: probe.emit),
        maximumRenderedMessageLength: 220
    )
    let event = try RadrootsTelemetryEvent(
        name: "field_ios.identity.import",
        category: "field_ios",
        level: .error,
        message: "imported nsec1secret",
        fields: [
            try .string("relay_light", "red"),
            try .string("selected_secret_key_name", "field identity")
        ],
        occurredAt: Date(timeIntervalSince1970: 10)
    )

    await telemetry.record(event)

    let record = try #require(probe.records.first)
    #expect(record.subsystem == "org.radroots.field_ios")
    #expect(record.category == "field_ios")
    #expect(record.level == .error)
    #expect(record.renderedMessage.contains("\"event\":\"field_ios.identity.import\""))
    #expect(record.renderedMessage.contains("\"message\":\"[redacted]\""))
    #expect(record.renderedMessage.contains("\"selected_secret_key_name\":\"[redacted]\""))
    #expect(!record.renderedMessage.contains("nsec1secret"))
    #expect(!record.renderedMessage.contains("field identity"))
    #expect(record.renderedMessage.count <= 220)
}

@Test func appleLoggerTelemetrySanitizesSubsystemAndCategory() async throws {
    #expect(RadrootsAppleLoggerTelemetry.normalizedSubsystem(" Field iOS / Local ") == "Field_iOS_Local")
    #expect(RadrootsAppleLoggerTelemetry.normalizedSubsystem("    ") == "org.radroots.apple_kit")
    #expect(RadrootsAppleLoggerTelemetry.normalizedCategory(" relay/status ") == "relay_status")
    #expect(RadrootsAppleLoggerTelemetry.normalizedCategory(" -- ") == "app")
}

@Test func appleLoggerTelemetryMapsLevelsToOsLogTypes() {
    #expect(RadrootsAppleTelemetryLogRecord(
        subsystem: "org.radroots.tests",
        category: "tests",
        level: .trace,
        renderedMessage: "{}"
    ).osLogType == .debug)
    #expect(RadrootsAppleTelemetryLogRecord(
        subsystem: "org.radroots.tests",
        category: "tests",
        level: .info,
        renderedMessage: "{}"
    ).osLogType == .info)
    #expect(RadrootsAppleTelemetryLogRecord(
        subsystem: "org.radroots.tests",
        category: "tests",
        level: .warning,
        renderedMessage: "{}"
    ).osLogType == .default)
    #expect(RadrootsAppleTelemetryLogRecord(
        subsystem: "org.radroots.tests",
        category: "tests",
        level: .error,
        renderedMessage: "{}"
    ).osLogType == .error)
    #expect(RadrootsAppleTelemetryLogRecord(
        subsystem: "org.radroots.tests",
        category: "tests",
        level: .critical,
        renderedMessage: "{}"
    ).osLogType == .fault)
}

@Test func appleLoggerTelemetryRendersSortedPayloads() throws {
    let event = try RadrootsTelemetryEvent(
        name: "field_ios.relay.status",
        category: "field_ios",
        level: .notice,
        fields: [
            try .integer("connecting_count", 1),
            try .integer("connected_count", 2)
        ],
        occurredAt: Date(timeIntervalSince1970: 1)
    )

    let rendered = RadrootsAppleLoggerTelemetry.renderedMessage(for: event)

    #expect(rendered.contains("\"category\":\"field_ios\""))
    #expect(rendered.contains("\"connected_count\":\"2\""))
    #expect(rendered.contains("\"connecting_count\":\"1\""))
    #expect(rendered.contains("\"event\":\"field_ios.relay.status\""))
    #expect(rendered.contains("\"level\":\"notice\""))
    #expect(rendered.contains("\"occurred_at_unix_ms\":1000"))
}

private final class RadrootsAppleLoggerTelemetryProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var recordsValue: [RadrootsAppleTelemetryLogRecord] = []

    func emit(_ record: RadrootsAppleTelemetryLogRecord) {
        lock.withLock {
            recordsValue.append(record)
        }
    }

    var records: [RadrootsAppleTelemetryLogRecord] {
        lock.withLock {
            recordsValue
        }
    }
}
