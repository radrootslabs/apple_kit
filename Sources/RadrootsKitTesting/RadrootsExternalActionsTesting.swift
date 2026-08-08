import Foundation
import RadrootsKit

public actor RadrootsFakeExternalActions: RadrootsExternalActions {
    private var capabilityOverrides: [RadrootsExternalActionDestination: Bool]
    private var defaultCanOpen: Bool
    private var openOutcome: Result<Void, RadrootsExternalActionError>
    private var capabilityRequestCountValue: Int
    private var openRequestCountValue: Int
    private var lastCapabilityDestinationValue: RadrootsExternalActionDestination?
    private var openedDestinationsValue: [RadrootsExternalActionDestination]

    public init(
        capabilityOverrides: [RadrootsExternalActionDestination: Bool] = [:],
        defaultCanOpen: Bool = true,
        openOutcome: Result<Void, RadrootsExternalActionError> = .success(())
    ) {
        self.capabilityOverrides = capabilityOverrides
        self.defaultCanOpen = defaultCanOpen
        self.openOutcome = openOutcome
        capabilityRequestCountValue = 0
        openRequestCountValue = 0
        lastCapabilityDestinationValue = nil
        openedDestinationsValue = []
    }

    public func setCapability(_ canOpen: Bool, for destination: RadrootsExternalActionDestination) {
        capabilityOverrides[destination] = canOpen
    }

    public func setDefaultCapability(_ canOpen: Bool) {
        defaultCanOpen = canOpen
    }

    public func setOpenOutcome(_ outcome: Result<Void, RadrootsExternalActionError>) {
        openOutcome = outcome
    }

    public func canOpen(_ destination: RadrootsExternalActionDestination) async -> RadrootsExternalActionCapability {
        capabilityRequestCountValue += 1
        lastCapabilityDestinationValue = destination
        return RadrootsExternalActionCapability(
            destination: destination,
            canOpen: capabilityOverrides[destination] ?? defaultCanOpen
        )
    }

    public func open(_ request: RadrootsExternalActionRequest) async throws {
        openRequestCountValue += 1
        openedDestinationsValue.append(request.destination)
        switch openOutcome {
        case .success:
            return
        case let .failure(error):
            throw error
        }
    }

    public var capabilityRequestCount: Int {
        capabilityRequestCountValue
    }

    public var openRequestCount: Int {
        openRequestCountValue
    }

    public var lastCapabilityDestination: RadrootsExternalActionDestination? {
        lastCapabilityDestinationValue
    }

    public var openedDestinations: [RadrootsExternalActionDestination] {
        openedDestinationsValue
    }

    public var lastOpenedDestination: RadrootsExternalActionDestination? {
        openedDestinationsValue.last
    }
}
