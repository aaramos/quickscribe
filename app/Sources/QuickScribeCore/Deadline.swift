import Foundation

public struct DeadlinePassed: Error {}

/// Returns the work's answer, or throws DeadlinePassed once time is up. It does not
/// wait for the abandoned work to stop, because a dictation must not hang on a model
/// that is slow to notice it was cancelled.
public func withDeadline<T: Sendable>(_ seconds: TimeInterval,
                                      _ work: @escaping @Sendable () async throws -> T) async throws -> T {
    try await withCheckedThrowingContinuation { (done: CheckedContinuation<T, Error>) in
        let once = ResumeOnce(done)
        let task = Task {
            do { once.resume(.success(try await work())) } catch { once.resume(.failure(error)) }
        }
        Task {
            try? await Task.sleep(nanoseconds: UInt64(max(0, seconds) * 1_000_000_000))
            if once.resume(.failure(DeadlinePassed())) { task.cancel() }
        }
    }
}

private final class ResumeOnce<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<T, Error>?

    init(_ continuation: CheckedContinuation<T, Error>) { self.continuation = continuation }

    @discardableResult
    func resume(_ result: Result<T, Error>) -> Bool {
        lock.lock()
        let waiting = continuation
        continuation = nil
        lock.unlock()
        waiting?.resume(with: result)
        return waiting != nil
    }
}
