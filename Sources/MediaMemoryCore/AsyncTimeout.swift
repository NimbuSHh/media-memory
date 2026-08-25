import Foundation

public struct AsyncTimeoutError: Error, LocalizedError, Equatable, Sendable {
    public let operationName: String

    public init(operationName: String) {
        self.operationName = operationName
    }

    public var errorDescription: String? {
        "\(operationName)超时，已取消当前任务；可以直接重试。"
    }
}

public enum AsyncTimeout {
    public static func run<Value: Sendable>(
        for duration: Duration,
        operationName: String,
        operation: @escaping @Sendable () async throws -> Value
    ) async throws -> Value {
        let race = AsyncTimeoutRace<Value>()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                guard race.install(continuation) else { return }

                let operationTask = Task {
                    do {
                        race.finish(.success(try await operation()))
                    } catch {
                        race.finish(.failure(error))
                    }
                }
                race.setOperationTask(operationTask)

                let timeoutTask = Task {
                    do {
                        try await Task.sleep(for: duration)
                        race.finish(.failure(AsyncTimeoutError(operationName: operationName)))
                    } catch is CancellationError {
                        // The operation or caller won the race.
                    } catch {
                        race.finish(.failure(error))
                    }
                }
                race.setTimeoutTask(timeoutTask)
            }
        } onCancel: {
            race.finish(.failure(CancellationError()))
        }
    }
}

/// A task group waits for cancelled children before returning. That makes it
/// unsuitable as a watchdog when a system API does not cooperate with Swift
/// cancellation. This small lock-protected race resumes the caller immediately
/// and still issues cancellation to the losing task.
private final class AsyncTimeoutRace<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var result: Result<Value, Error>?
    private var continuation: CheckedContinuation<Value, Error>?
    private var operationTask: Task<Void, Never>?
    private var timeoutTask: Task<Void, Never>?

    /// Returns false when cancellation completed the race before the
    /// continuation was installed; in that case this method resumes it.
    func install(_ continuation: CheckedContinuation<Value, Error>) -> Bool {
        lock.lock()
        if let result {
            lock.unlock()
            continuation.resume(with: result)
            return false
        }
        self.continuation = continuation
        lock.unlock()
        return true
    }

    func setOperationTask(_ task: Task<Void, Never>) {
        lock.lock()
        let shouldCancel = result != nil
        if !shouldCancel { operationTask = task }
        lock.unlock()
        if shouldCancel { task.cancel() }
    }

    func setTimeoutTask(_ task: Task<Void, Never>) {
        lock.lock()
        let shouldCancel = result != nil
        if !shouldCancel { timeoutTask = task }
        lock.unlock()
        if shouldCancel { task.cancel() }
    }

    func finish(_ result: Result<Value, Error>) {
        lock.lock()
        guard self.result == nil else {
            lock.unlock()
            return
        }
        self.result = result
        let continuation = continuation
        self.continuation = nil
        let operationTask = operationTask
        self.operationTask = nil
        let timeoutTask = timeoutTask
        self.timeoutTask = nil
        lock.unlock()

        operationTask?.cancel()
        timeoutTask?.cancel()
        continuation?.resume(with: result)
    }
}
