import Foundation

struct RadrootsTransferCompletion: Sendable {
    let platformError: (any Error)?
    let stagedDownloadResult: RadrootsStagedBackgroundDownloadResult?
    let httpResult: RadrootsBackgroundHTTPResult
    let bytesTransferred: Int64
    let totalBytesExpected: Int64?
}
