import Foundation
import RadrootsKit

public actor RadrootsFakeBackgroundTaskScheduler: RadrootsBackgroundTaskScheduler {
    private var pendingTaskSnapshots: [RadrootsBackgroundTaskIdentifier: RadrootsBackgroundTaskSnapshot]
    private var submittedRequestsValue: [RadrootsBackgroundTaskRequest]
    private var cancelledIdentifiersValue: [RadrootsBackgroundTaskIdentifier]
    private var cancelAllCountValue: Int
    private var submitOutcome: Result<Void, RadrootsBackgroundTaskError>
    private let submittedAt: Date

    public init(
        pendingTasks: [RadrootsBackgroundTaskSnapshot] = [],
        submitOutcome: Result<Void, RadrootsBackgroundTaskError> = .success(()),
        submittedAt: Date = Date(timeIntervalSince1970: 0)
    ) {
        pendingTaskSnapshots = Dictionary(uniqueKeysWithValues: pendingTasks.map { ($0.identifier, $0) })
        submittedRequestsValue = []
        cancelledIdentifiersValue = []
        cancelAllCountValue = 0
        self.submitOutcome = submitOutcome
        self.submittedAt = submittedAt
    }

    public func setSubmitOutcome(_ outcome: Result<Void, RadrootsBackgroundTaskError>) {
        submitOutcome = outcome
    }

    public func submit(_ request: RadrootsBackgroundTaskRequest) async throws -> RadrootsBackgroundTaskSnapshot {
        submittedRequestsValue.append(request)
        switch submitOutcome {
        case .success:
            let snapshot = try RadrootsBackgroundTaskSnapshot(request: request, submittedAt: submittedAt)
            pendingTaskSnapshots[request.identifier] = snapshot
            return snapshot
        case let .failure(error):
            throw error
        }
    }

    public func cancel(_ identifier: RadrootsBackgroundTaskIdentifier) async throws {
        cancelledIdentifiersValue.append(identifier)
        pendingTaskSnapshots.removeValue(forKey: identifier)
    }

    public func cancelAll() async throws {
        cancelAllCountValue += 1
        pendingTaskSnapshots.removeAll()
    }

    public func pendingTasks() async throws -> [RadrootsBackgroundTaskSnapshot] {
        pendingTaskSnapshots.values.sorted { lhs, rhs in
            lhs.identifier < rhs.identifier
        }
    }

    public var submittedRequests: [RadrootsBackgroundTaskRequest] {
        submittedRequestsValue
    }

    public var submittedRequestCount: Int {
        submittedRequestsValue.count
    }

    public var cancelledIdentifiers: [RadrootsBackgroundTaskIdentifier] {
        cancelledIdentifiersValue
    }

    public var cancelAllCount: Int {
        cancelAllCountValue
    }
}
