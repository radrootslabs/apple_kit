import Foundation
import RadrootsKit

public actor RadrootsRecordingTelemetry: RadrootsTelemetry {
    private let minimumLevel: RadrootsTelemetryLevel
    private var recordedEventsValue: [RadrootsTelemetryEvent]

    public init(minimumLevel: RadrootsTelemetryLevel = .trace) {
        self.minimumLevel = minimumLevel
        recordedEventsValue = []
    }

    public func record(_ event: RadrootsTelemetryEvent) async {
        guard event.level >= minimumLevel else {
            return
        }
        recordedEventsValue.append(event)
    }

    public func reset() {
        recordedEventsValue.removeAll()
    }

    public var recordedEvents: [RadrootsTelemetryEvent] {
        recordedEventsValue
    }

    public var recordedEventCount: Int {
        recordedEventsValue.count
    }

    public var recordedEventNames: [String] {
        recordedEventsValue.map(\.name)
    }

    public func events(named name: String) -> [RadrootsTelemetryEvent] {
        recordedEventsValue.filter { $0.name == name }
    }
}
