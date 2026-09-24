import Foundation
import Testing

@testable import RadrootsKit

@Test func presenceCancellationBeforeContinuationInstallationRetainsCancellation() async {
    let state = RadrootsAppleUserPresenceAsyncCallbackState<Bool>(invalidate: {})
    state.resume(.failure(.userCancelled))
    await #expect(throws: RadrootsUserPresenceError.userCancelled) {
        try await withCheckedThrowingContinuation { continuation in
            state.install(continuation, timeoutNanoseconds: 1_000_000_000) { _ in
                Issue.record("Cancelled presence must not start authentication")
            }
        }
    }
}

@Test(arguments: [Double.nan, Double.infinity, 0, -1, Double(UInt64.max) / 1e9])
func presenceRejectsInvalidTimeoutBeforeStarting(timeout: Double) async {
    await #expect(throws: RadrootsUserPresenceError.invalidRequest) {
        let _: Bool = try await RadrootsAppleUserPresenceAsyncSupport.awaitCallback(
            timeout: timeout, timeoutMessage: "unused"
        ) { _ in
            Issue.record("Invalid timeout must not start authentication")
        }
    }
}

#if canImport(LocalAuthentication)
    import LocalAuthentication

    @Test func presenceAlreadyCancelledTaskInvalidatesContextWithoutEvaluation() async throws {
        let context = ControlledPresenceContext()
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await RadrootsAppleUserPresenceAdapters.verify(
                RadrootsUserPresenceRequest(reason: "Test cancellation"),
                context: context, callbackTimeout: 1
            )
        }
        await #expect(throws: RadrootsUserPresenceError.userCancelled) { try await task.value }
        #expect(context.counts == [0, 1])
    }

    @Test func presenceCancellationDuringEvaluationInvalidatesAndIgnoresLateSuccess() async throws {
        let context = ControlledPresenceContext()
        let task = Task {
            try await RadrootsAppleUserPresenceAdapters.verify(
                RadrootsUserPresenceRequest(reason: "Test cancellation"),
                context: context, callbackTimeout: 1
            )
        }
        for await _ in context.started { break }
        task.cancel()
        await #expect(throws: RadrootsUserPresenceError.userCancelled) { try await task.value }
        context.complete(success: true)
        context.complete(success: false)
        #expect(context.counts == [1, 1])
    }

    @Test func presenceTimeoutInvalidatesActualContext() async throws {
        let context = ControlledPresenceContext()
        await #expect(throws: RadrootsUserPresenceError.timeout) {
            try await RadrootsAppleUserPresenceAdapters.verify(
                RadrootsUserPresenceRequest(reason: "Test timeout"),
                context: context, callbackTimeout: 0.001
            )
        }
        #expect(context.counts == [1, 1])
    }

    @Test func presenceSuccessAndDuplicateCallbackResolveOnce() async throws {
        let context = ControlledPresenceContext()
        let task = Task {
            try await RadrootsAppleUserPresenceAdapters.verify(
                RadrootsUserPresenceRequest(reason: "Test success"),
                context: context, callbackTimeout: 1
            )
        }
        for await _ in context.started { break }
        context.complete(success: true)
        context.complete(success: false)
        #expect(try await task.value.verified)
        #expect(context.counts == [1, 1])
    }

    // NSLock protects test observations and the callback across the operation queue.
    private final class ControlledPresenceContext: LAContext, @unchecked Sendable {
        private let lock = NSLock()
        private var evaluations = 0
        private var invalidations = 0
        private var reply: (@Sendable (Bool, (any Error)?) -> Void)?
        let started: AsyncStream<Void>
        private let signal: AsyncStream<Void>.Continuation

        override init() {
            (started, signal) = AsyncStream.makeStream()
            super.init()
        }

        override func evaluatePolicy(
            _ policy: LAPolicy, localizedReason: String,
            reply: @escaping @Sendable (Bool, (any Error)?) -> Void
        ) {
            lock.lock()
            evaluations += 1
            self.reply = reply
            lock.unlock()
            signal.yield(())
        }

        override func invalidate() {
            lock.lock()
            invalidations += 1
            lock.unlock()
        }

        func complete(success: Bool) {
            lock.lock()
            let callback = reply
            lock.unlock()
            callback?(success, nil)
        }

        var counts: [Int] {
            lock.lock()
            defer { lock.unlock() }
            return [evaluations, invalidations]
        }
    }
#endif
