import Foundation

enum AsyncOperationPriority: Int, Sendable {
    case background = 0
    case foreground = 1
}

/// A one-at-a-time asynchronous gate whose queued callers remain cancellable.
///
/// `CheckedContinuation<Void, Never>` queues cannot remove a cancelled waiter,
/// which makes unrelated UI actions wait behind work the user already stopped.
/// This gate gives every waiter an identity and resumes cancelled waiters with
/// `CancellationError` immediately.
actor AsyncOperationGate {
    private struct Waiter {
        let id: UUID
        let priority: AsyncOperationPriority
        let continuation: CheckedContinuation<Bool, Never>
    }

    private var isLocked = false
    private var waiters: [Waiter] = []

    func acquire(priority: AsyncOperationPriority = .background) async throws {
        try Task.checkCancellation()
        let waiterID = UUID()
        let acquired = await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                if !isLocked {
                    isLocked = true
                    continuation.resume(returning: true)
                } else {
                    waiters.append(
                        Waiter(
                            id: waiterID,
                            priority: priority,
                            continuation: continuation
                        )
                    )
                }
            }
        } onCancel: {
            Task { await self.cancel(waiterID: waiterID) }
        }

        guard acquired, !Task.isCancelled else {
            if acquired {
                release()
            }
            throw CancellationError()
        }
    }

    func release() {
        if let highestPriority = waiters.map(\.priority).max(by: { $0.rawValue < $1.rawValue }),
           let index = waiters.firstIndex(where: { $0.priority == highestPriority }) {
            let waiter = waiters.remove(at: index)
            waiter.continuation.resume(returning: true)
        } else {
            isLocked = false
        }
    }

    private func cancel(waiterID: UUID) {
        guard let index = waiters.firstIndex(where: { $0.id == waiterID }) else {
            return
        }
        let waiter = waiters.remove(at: index)
        waiter.continuation.resume(returning: false)
    }
}
