import Foundation

extension RadrootsBackgroundTransferSnapshot {
    func transitioned(
        to state: RadrootsBackgroundTransferState, at date: Date,
        failure: RadrootsBackgroundTransferFailure? = nil,
        possibleRemoteOrphan: Bool = false
    ) throws -> Self {
        try Self(
            request: request, state: state, progress: progress, failure: failure,
            response: state == .completed ? response : nil,
            downloadedArtifact: state == .completed ? downloadedArtifact : nil,
            possibleRemoteOrphan: possibleRemoteOrphan, updatedAt: date,
            executionID: executionID, uploadLease: uploadLease
        )
    }
}
