import Foundation

/// 描述车道：串行消费"已建库但缺少当前版本描述"的片段，逐个调用 Qwen3.8。
/// 与证据车道（SegmentIndexer）并行运行；暂停与恢复通过任务取消实现，
/// 重启后由 reconcile 恢复队列，已完成的描述直接命中缓存。
public actor DescriptionQueue {
    public typealias EventHandler = @Sendable (IndexingEvent) async -> Void

    private let database: MediaDatabase
    private let descriptionService: DescriptionService

    public init(database: MediaDatabase, descriptionService: DescriptionService) {
        self.database = database
        self.descriptionService = descriptionService
    }

    public func prepareQueue() async throws -> IndexingProgress {
        try await database.reconcileDescribeJobs()
        return try await database.describeProgress()
    }

    public func progress() async throws -> IndexingProgress {
        try await database.describeProgress()
    }

    public func retryFailed() async throws -> IndexingProgress {
        try await database.retryFailedJobs(kind: .describeSegment)
        return try await database.describeProgress()
    }

    /// 仅供应用级后台协调器在启动时调用；在线补队不会回收 running。
    public func recoverInterrupted() async throws -> IndexingProgress {
        try await database.recoverInterruptedJobs(kind: .describeSegment)
        return try await prepareQueue()
    }

    public func runUntilIdle(onEvent: EventHandler? = nil) async throws -> IndexRunSummary {
        _ = try await prepareQueue()
        var succeeded = 0
        var failed = 0
        laneLoop: while !Task.isCancelled {
            let target: SegmentIndexTarget
            switch try await database.claimNextDescribeJob() {
            case .target(let value):
                target = value
            case .idle:
                break laneLoop
            }
            do {
                try Task.checkCancellation()
                try await database.updateIndexJob(
                    claim: target.job.claimToken,
                    stage: "describing"
                )
                await publish(target: target, stage: "describing", onEvent: onEvent)
                _ = try await descriptionService.description(for: target)
                succeeded += 1
                await publish(target: target, stage: "described", onEvent: onEvent)
            } catch is CancellationError {
                try await returnToQueue(target.job.claimToken)
                throw CancellationError()
            } catch MediaDatabaseDerivationError.descriptionInputChanged {
                try await returnToQueue(
                    target.job.claimToken,
                    stage: "input_changed"
                )
            } catch MediaDatabaseDerivationError.missingTarget {
                try await returnToQueue(
                    target.job.claimToken,
                    stage: "target_unavailable"
                )
            } catch DescriptionServiceError.missingSegment {
                try await returnToQueue(
                    target.job.claimToken,
                    stage: "target_unavailable"
                )
            } catch MediaDatabaseDerivationError.staleClaim {
                continue
            } catch {
                if try await fail(
                    target.job.claimToken,
                    message: error.localizedDescription
                ) {
                    failed += 1
                    await publish(target: target, stage: "describe_failed", onEvent: onEvent)
                }
            }
        }
        try Task.checkCancellation()
        return IndexRunSummary(succeeded: succeeded, failed: failed)
    }

    private func returnToQueue(
        _ claim: JobClaimToken,
        stage: String = "paused"
    ) async throws {
        do {
            try await database.returnIndexJobToQueue(claim: claim, stage: stage)
        } catch MediaDatabaseDerivationError.staleClaim {
            // Recovery or deletion already invalidated this execution.
        }
    }

    private func fail(_ claim: JobClaimToken, message: String) async throws -> Bool {
        do {
            try await database.failIndexJob(claim: claim, message: message)
            return true
        } catch MediaDatabaseDerivationError.staleClaim {
            // A newer attempt owns the job; the old execution cannot fail it.
            return false
        }
    }

    private func publish(
        target: SegmentIndexTarget,
        stage: String,
        onEvent: EventHandler?
    ) async {
        guard let onEvent, let progress = try? await database.describeProgress() else { return }
        await onEvent(
            IndexingEvent(
                assetID: target.asset.id,
                assetName: target.asset.filename,
                segmentOrdinal: target.segment.ordinal,
                stage: stage,
                progress: progress
            )
        )
    }
}
