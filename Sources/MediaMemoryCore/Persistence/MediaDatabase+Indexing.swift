import Foundation

public enum MediaDatabaseDerivationError: Error, LocalizedError, Sendable {
    case missingTarget
    case sourceChanged
    case invalidVector
    case staleClaim
    case descriptionInputChanged

    public var errorDescription: String? {
        switch self {
        case .missingTarget:
            "待处理片段已经不存在。"
        case .sourceChanged:
            "处理期间源视频发生了变化；结果已丢弃，请重新扫描。"
        case .invalidVector:
            "数据库中的向量数据无效。"
        case .staleClaim:
            "任务认领已经失效；陈旧执行结果已丢弃。"
        case .descriptionInputChanged:
            "描述生成期间片段证据发生了变化；旧描述已丢弃。"
        }
    }
}

extension MediaDatabase {
    public func reconcileIndexJobs(
        embeddingModelID: String,
        inputVersion: String,
        now: Date = Date()
    ) throws {
        try connection.inTransaction {
            let invalidate = try connection.prepare(
                """
                UPDATE job
                SET status = 'pending', checkpoint_json = ?, error_message = NULL, updated_at = ?
                WHERE kind = 'index_segment'
                  AND status <> 'running'
                  AND segment_id IN (
                      SELECT e.segment_id
                      FROM segment_embedding e
                      WHERE e.model_id <> ? OR e.input_version <> ?
                  )
                """
            )
            try invalidate.bind(.text(checkpoint(stage: "model_changed")), at: 1)
            try invalidate.bind(.real(now.timeIntervalSince1970), at: 2)
            try invalidate.bind(.text(embeddingModelID), at: 3)
            try invalidate.bind(.text(inputVersion), at: 4)
            _ = try invalidate.step()

            let enqueue = try connection.prepare(
                """
                INSERT INTO job (
                    id, asset_id, segment_id, kind, status, attempt_count,
                    checkpoint_json, error_message, created_at, updated_at
                )
                SELECT lower(hex(randomblob(16))), s.asset_id, s.id,
                       'index_segment', 'pending', 0, ?, NULL, ?, ?
                FROM segment s
                JOIN media_asset a ON a.id = s.asset_id
                LEFT JOIN segment_embedding e
                    ON e.segment_id = s.id
                   AND e.model_id = ?
                   AND e.input_version = ?
                LEFT JOIN job j
                    ON j.segment_id = s.id AND j.kind = 'index_segment'
                WHERE a.status = 'ready'
                  AND a.invalidated_at IS NULL
                  AND a.is_excluded = 0
                  AND (
                    s.is_active = 1
                    OR EXISTS (
                        SELECT 1 FROM derivation_run sr
                        WHERE sr.id = s.segmentation_run_id
                          AND sr.kind = 'segmentation' AND sr.status = 'running'
                    )
                  )
                  AND NOT (
                    s.segmentation_run_id IS NULL
                    AND EXISTS (
                        SELECT 1 FROM job sj
                        WHERE sj.asset_id = s.asset_id
                          AND sj.kind = 'segment_asset'
                    )
                  )
                  AND e.segment_id IS NULL
                  AND j.id IS NULL
                """
            )
            try enqueue.bind(.text(checkpoint(stage: "queued")), at: 1)
            try enqueue.bind(.real(now.timeIntervalSince1970), at: 2)
            try enqueue.bind(.real(now.timeIntervalSince1970), at: 3)
            try enqueue.bind(.text(embeddingModelID), at: 4)
            try enqueue.bind(.text(inputVersion), at: 5)
            _ = try enqueue.step()
        }
    }

    /// 应用级后台协调器在确认旧进程已不存在后显式调用一次。
    /// 在线 reconcile 永远不会回收仍在运行的任务。
    public func recoverInterruptedJobs(kind: JobKind, now: Date = Date()) throws {
        let statement = try connection.prepare(
            """
            UPDATE job
            SET status = 'pending', checkpoint_json = ?, error_message = NULL, updated_at = ?
            WHERE kind = ? AND status = 'running'
            """
        )
        try statement.bind(.text(checkpoint(stage: "recovered")), at: 1)
        try statement.bind(.real(now.timeIntervalSince1970), at: 2)
        try statement.bind(.text(kind.rawValue), at: 3)
        _ = try statement.step()
    }

    /// Checks whether a claimed target is still eligible for background input
    /// reads. Used after a filesystem read fails to distinguish a concurrently
    /// confirmed missing/deleted asset from a genuine processing failure.
    public func isIndexTargetAvailable(
        assetID: String,
        sourceFingerprint: String
    ) throws -> Bool {
        let statement = try connection.prepare(
            """
            SELECT 1 FROM media_asset
            WHERE id = ? AND fingerprint = ? AND status = 'ready'
              AND invalidated_at IS NULL AND is_excluded = 0
            """
        )
        try statement.bind(.text(assetID), at: 1)
        try statement.bind(.text(sourceFingerprint), at: 2)
        return try statement.step()
    }

    /// Changes whenever another SQLite connection commits. Search uses this to
    /// reject multi-phase semantic reads that crossed a writer commit.
    public func dataVersion() throws -> Int64 {
        let statement = try connection.prepare("PRAGMA data_version")
        guard try statement.step() else { return 0 }
        return statement.integer(at: 0)
    }

    /// Literal candidates and their playback/evidence context must come from one
    /// WAL snapshot; otherwise a rescan could bind old evidence to a new source.
    public func literalSearchSnapshot(
        query: String,
        limit: Int
    ) throws -> LiteralSearchSnapshot {
        try connection.inReadTransaction {
            let matches = try literalSearch(query: query, limit: limit)
            var contexts: [String: SegmentSearchContext] = [:]
            for segmentID in Set(matches.map(\.segmentID)) {
                contexts[segmentID] = try searchContext(segmentID: segmentID)
            }
            return LiteralSearchSnapshot(matches: matches, contexts: contexts)
        }
    }

    public func claimNextIndexJob(now: Date = Date()) throws -> JobClaim {
        try claimNextJob(kind: .indexSegment, requiresEmbedding: false, now: now)
    }

    /// 描述车道的任务认领；只处理当前仍有有效向量的片段。
    public func claimNextDescribeJob(now: Date = Date()) throws -> JobClaim {
        try claimNextJob(kind: .describeSegment, requiresEmbedding: true, now: now)
    }

    /// 供证据车道按全局队列顺序预读下一个任务，不改变任务状态，
    /// 也不认领任务或影响描述车道。
    public func peekNextIndexJob() throws -> SegmentIndexTarget? {
        guard let row = try selectNextJob(
            kind: "index_segment",
            requiresEmbedding: false,
            restrictAssetID: nil
        ) else { return nil }
        return SegmentIndexTarget(
            job: IndexJobRecord(
                id: row.jobID,
                assetID: row.assetID,
                segmentID: row.segmentID,
                status: .pending,
                attemptCount: row.attemptCount,
                stage: nil,
                errorMessage: nil,
                createdAt: row.createdAt,
                updatedAt: row.createdAt
            ),
            asset: row.asset,
            segment: row.segment,
            descriptionInputRevision: nil
        )
    }

    private struct NextJobRow {
        let jobID: String
        let assetID: String
        let segmentID: String
        let attemptCount: Int
        let createdAt: Date
        let asset: MediaAssetRecord
        let segment: SegmentRecord
        let descriptionInputRevision: String?
    }

    /// 两条业务车道各自只认领自己的任务。共享资源由模型运行时仲裁，
    /// 不通过任务状态或视频门互相阻塞。
    private func claimNextJob(
        kind: JobKind,
        requiresEmbedding: Bool,
        now: Date
    ) throws -> JobClaim {
        try connection.inTransaction {
            guard let row = try selectNextJob(
                kind: kind.rawValue,
                requiresEmbedding: requiresEmbedding,
                restrictAssetID: nil
            ) else {
                return .idle
            }
            return .target(try startJob(row, now: now))
        }
    }

    private func startJob(_ row: NextJobRow, now: Date) throws -> SegmentIndexTarget {
        let attempt = row.attemptCount + 1
        let update = try connection.prepare(
            """
            UPDATE job
            SET status = 'running', attempt_count = ?, checkpoint_json = ?,
                error_message = NULL, updated_at = ?
            WHERE id = ? AND status = 'pending'
            RETURNING id
            """
        )
        try update.bind(.integer(Int64(attempt)), at: 1)
        try update.bind(.text(checkpoint(stage: "starting")), at: 2)
        try update.bind(.real(now.timeIntervalSince1970), at: 3)
        try update.bind(.text(row.jobID), at: 4)
        guard try update.step() else { throw MediaDatabaseDerivationError.staleClaim }

        return SegmentIndexTarget(
            job: IndexJobRecord(
                id: row.jobID,
                assetID: row.assetID,
                segmentID: row.segmentID,
                status: .running,
                attemptCount: attempt,
                stage: "starting",
                errorMessage: nil,
                createdAt: row.createdAt,
                updatedAt: now
            ),
            asset: row.asset,
            segment: row.segment,
            descriptionInputRevision: row.descriptionInputRevision
        )
    }

    private func selectNextJob(
        kind: String,
        requiresEmbedding: Bool,
        restrictAssetID: String?
    ) throws -> NextJobRow? {
        let embeddingJoin = requiresEmbedding
            ? "JOIN segment_embedding e ON e.segment_id = s.id"
            : ""
        let assetFilter = restrictAssetID != nil ? "AND a.id = ?" : ""
        let segmentEligibility = """
            AND (
                s.is_active = 1
                OR EXISTS (
                    SELECT 1 FROM derivation_run sr
                    WHERE sr.id = s.segmentation_run_id
                      AND sr.kind = 'segmentation' AND sr.status = 'running'
                )
            )
            AND NOT (
                s.segmentation_run_id IS NULL
                AND EXISTS (
                    SELECT 1 FROM job sj
                    WHERE sj.asset_id = s.asset_id
                      AND sj.kind = 'segment_asset'
                )
            )
            """
        let query = try connection.prepare(
            """
            SELECT j.id, j.asset_id, j.segment_id, j.status, j.attempt_count,
                   j.checkpoint_json, j.error_message, j.created_at, j.updated_at,
                   a.id, a.root_id, a.relative_path, a.standardized_path,
                   a.file_size, a.modification_time, a.duration_ms,
                   a.video_track_count, a.audio_track_count, a.is_playable,
                   a.fingerprint, a.status, a.error_message,
                   a.first_seen_at, a.last_seen_at,
                   s.id, s.asset_id, s.ordinal, s.start_ms, s.end_ms,
                   s.segmentation_version,
                   \(requiresEmbedding ? "e.derivation_run_id" : "NULL")
            FROM job j
            JOIN media_asset a ON a.id = j.asset_id
            JOIN segment s ON s.id = j.segment_id
            \(embeddingJoin)
            WHERE j.kind = ?
              AND j.status = 'pending'
              AND a.status = 'ready'
              AND a.invalidated_at IS NULL
              AND a.is_excluded = 0
              \(segmentEligibility)
              \(assetFilter)
            ORDER BY a.relative_path COLLATE NOCASE, s.ordinal
            LIMIT 1
            """
        )
        try query.bind(.text(kind), at: 1)
        if let restrictAssetID {
            try query.bind(.text(restrictAssetID), at: 2)
        }
        guard try query.step(),
              let jobID = query.text(at: 0),
              let assetID = query.text(at: 1),
              let segmentID = query.text(at: 2),
              let asset = assetRecord(from: query, offset: 9),
              let segment = segmentRecord(from: query, offset: 24) else {
            return nil
        }
        return NextJobRow(
            jobID: jobID,
            assetID: assetID,
            segmentID: segmentID,
            attemptCount: Int(query.integer(at: 4)),
            createdAt: Date(timeIntervalSince1970: query.real(at: 7)),
            asset: asset,
            segment: segment,
            descriptionInputRevision: query.text(at: 30)
        )
    }

    /// 描述车道：过期描述重新入队、新片段入队。启动恢复由协调器显式调用。
    /// 一个片段需要描述当且仅当：已有当前版本的向量，且
    /// 不存在描述或描述记录的证据 revision 与当前向量 revision 不同。
    /// prompt/模型变更属于配置性失效：不自动重跑，由界面标记旧版并手动触发。
    public func reconcileDescribeJobs(now: Date = Date()) throws {
        try connection.inTransaction {
            // Descriptions created before evidence revisions were persisted are
            // still valid when the old invariant proves they were generated
            // after the current evidence commit and from the same source file.
            // Adopt that current immutable revision once instead of treating a
            // missing legacy field as evidence change and requeueing forever.
            let adoptLegacyRevision = try connection.prepare(
                """
                UPDATE derivation_run
                SET parameters_json = json_set(
                    parameters_json,
                    '$.input_revision',
                    (
                        SELECT e.derivation_run_id
                        FROM segment_description d
                        JOIN segment_embedding e ON e.segment_id = d.segment_id
                        JOIN segment s ON s.id = d.segment_id
                        JOIN media_asset a ON a.id = s.asset_id
                        WHERE d.derivation_run_id = derivation_run.id
                          AND a.status = 'ready'
                          AND a.invalidated_at IS NULL
                          AND a.is_excluded = 0
                          AND derivation_run.source_fingerprint = a.fingerprint
                          AND d.created_at >= e.created_at
                        LIMIT 1
                    )
                )
                WHERE kind = 'description'
                  AND status = 'succeeded'
                  AND json_valid(parameters_json)
                  AND json_extract(parameters_json, '$.input_revision') IS NULL
                  AND EXISTS (
                      SELECT 1
                      FROM segment_description d
                      JOIN segment_embedding e ON e.segment_id = d.segment_id
                      JOIN segment s ON s.id = d.segment_id
                      JOIN media_asset a ON a.id = s.asset_id
                      WHERE d.derivation_run_id = derivation_run.id
                        AND a.status = 'ready'
                        AND a.invalidated_at IS NULL
                        AND a.is_excluded = 0
                        AND derivation_run.source_fingerprint = a.fingerprint
                        AND d.created_at >= e.created_at
                  )
                """
            )
            _ = try adoptLegacyRevision.step()

            // A previous build may already have changed these jobs to pending.
            // If the saved cache now proves it belongs to the current evidence
            // revision, restore completion without invoking the model.
            let restoreCurrentCache = try connection.prepare(
                """
                UPDATE job
                SET status = 'succeeded', checkpoint_json = ?,
                    error_message = NULL, updated_at = ?
                WHERE kind = 'describe_segment'
                  AND status <> 'succeeded'
                  AND segment_id IN (
                      SELECT d.segment_id
                      FROM segment_description d
                      JOIN derivation_run dr ON dr.id = d.derivation_run_id
                      JOIN segment_embedding e ON e.segment_id = d.segment_id
                      JOIN segment s ON s.id = d.segment_id
                      JOIN media_asset a ON a.id = s.asset_id
                      WHERE a.status = 'ready'
                        AND a.invalidated_at IS NULL
                        AND a.is_excluded = 0
                        AND json_extract(
                            dr.parameters_json,
                            '$.input_revision'
                        ) = e.derivation_run_id
                  )
                """
            )
            try restoreCurrentCache.bind(.text(checkpoint(stage: "complete")), at: 1)
            try restoreCurrentCache.bind(.real(now.timeIntervalSince1970), at: 2)
            _ = try restoreCurrentCache.step()

            let stale = try connection.prepare(
                """
                UPDATE job
                SET status = 'pending', checkpoint_json = ?, error_message = NULL, updated_at = ?
                WHERE kind = 'describe_segment'
                  AND status IN ('succeeded', 'failed', 'cancelled')
                  AND segment_id IN (
                      SELECT s.id
                      FROM segment s
                      JOIN media_asset a ON a.id = s.asset_id
                      JOIN segment_description d ON d.segment_id = s.id
                      JOIN segment_embedding e ON e.segment_id = s.id
                      LEFT JOIN derivation_run dr ON dr.id = d.derivation_run_id
                      WHERE a.status = 'ready' AND a.invalidated_at IS NULL AND a.is_excluded = 0
                        AND coalesce(
                            json_extract(dr.parameters_json, '$.input_revision'),
                            ''
                        ) <> e.derivation_run_id
                  )
                """
            )
            try stale.bind(.text(checkpoint(stage: "description_outdated")), at: 1)
            try stale.bind(.real(now.timeIntervalSince1970), at: 2)
            _ = try stale.step()

            let enqueue = try connection.prepare(
                """
                INSERT INTO job (
                    id, asset_id, segment_id, kind, status, attempt_count,
                    checkpoint_json, error_message, created_at, updated_at
                )
                SELECT lower(hex(randomblob(16))), s.asset_id, s.id,
                       'describe_segment', 'pending', 0, ?, NULL, ?, ?
                FROM segment s
                JOIN segment_embedding e ON e.segment_id = s.id
                JOIN media_asset a ON a.id = s.asset_id
                LEFT JOIN segment_description d ON d.segment_id = s.id
                LEFT JOIN derivation_run dr ON dr.id = d.derivation_run_id
                LEFT JOIN job j
                    ON j.segment_id = s.id AND j.kind = 'describe_segment'
                WHERE a.status = 'ready'
                  AND a.invalidated_at IS NULL
                  AND a.is_excluded = 0
                  AND (
                    s.is_active = 1
                    OR EXISTS (
                        SELECT 1 FROM derivation_run sr
                        WHERE sr.id = s.segmentation_run_id
                          AND sr.kind = 'segmentation' AND sr.status = 'running'
                    )
                  )
                  AND (
                      d.segment_id IS NULL
                      OR coalesce(
                          json_extract(dr.parameters_json, '$.input_revision'),
                          ''
                      ) <> e.derivation_run_id
                  )
                  AND NOT (
                    s.segmentation_run_id IS NULL
                    AND EXISTS (
                        SELECT 1 FROM job sj
                        WHERE sj.asset_id = s.asset_id
                          AND sj.kind = 'segment_asset'
                    )
                  )
                  AND j.id IS NULL
                """
            )
            try enqueue.bind(.text(checkpoint(stage: "queued")), at: 1)
            try enqueue.bind(.real(now.timeIntervalSince1970), at: 2)
            try enqueue.bind(.real(now.timeIntervalSince1970), at: 3)
            _ = try enqueue.step()
        }
    }

    /// 失败任务摘要（带资产名、片段序号与错误原因），供界面展示。
    public func failedJobSummaries(limit: Int = 100) throws -> [FailedJobSummary] {
        let statement = try connection.prepare(
            """
            SELECT j.id, a.relative_path, s.ordinal, j.kind,
                   coalesce(j.error_message, '未知错误'), j.updated_at
            FROM job j
            JOIN media_asset a ON a.id = j.asset_id
            LEFT JOIN segment s ON s.id = j.segment_id
            WHERE j.status IN ('failed', 'cancelled')
              AND (
                j.kind = 'segment_asset'
                OR s.is_active = 1
                OR EXISTS (
                    SELECT 1 FROM derivation_run sr
                    WHERE sr.id = s.segmentation_run_id
                      AND sr.kind = 'segmentation' AND sr.status = 'running'
                )
              )
              AND (
                j.kind = 'segment_asset'
                OR j.status = 'running'
                OR NOT (
                    s.segmentation_run_id IS NULL
                    AND EXISTS (
                        SELECT 1 FROM job sj
                        WHERE sj.asset_id = s.asset_id
                          AND sj.kind = 'segment_asset'
                    )
                )
              )
            ORDER BY j.updated_at DESC
            LIMIT ?
            """
        )
        try statement.bind(.integer(Int64(max(1, limit))), at: 1)
        var summaries: [FailedJobSummary] = []
        while try statement.step(),
              let jobID = statement.text(at: 0),
              let assetName = statement.text(at: 1),
              let kind = statement.text(at: 3),
              let message = statement.text(at: 4) {
            summaries.append(
                FailedJobSummary(
                    jobID: jobID,
                    assetName: (assetName as NSString).lastPathComponent,
                    segmentOrdinal: statement.text(at: 2) == nil
                        ? nil : Int(statement.integer(at: 2)),
                    kind: kind,
                    message: message,
                    updatedAt: Date(timeIntervalSince1970: statement.real(at: 5))
                )
            )
        }
        return summaries
    }

    /// 配置性过期（prompt 或描述模型变化）的描述数量；只统计，不重跑。
    public func staleDescriptionCount(
        descriptionModelID: String,
        promptVersion: String
    ) throws -> Int {
        let statement = try connection.prepare(
            """
            SELECT count(*)
            FROM segment_description d
            JOIN segment s ON s.id = d.segment_id
            JOIN media_asset a ON a.id = s.asset_id
            JOIN derivation_run r ON r.id = d.derivation_run_id
            WHERE a.status = 'ready'
              AND a.invalidated_at IS NULL
              AND a.is_excluded = 0
              AND s.is_active = 1
              AND (d.prompt_version <> ? OR r.model_id <> ?)
            """
        )
        try statement.bind(.text(promptVersion), at: 1)
        try statement.bind(.text(descriptionModelID), at: 2)
        guard try statement.step() else { return 0 }
        return Int(statement.integer(at: 0))
    }

    /// 手动重跑整个视频的描述：丢弃缓存并把该视频的描述任务重置。
    public func requeueAssetDescriptions(assetID: String, now: Date = Date()) throws {
        try connection.inTransaction {
            let deleteDescriptions = try connection.prepare(
                """
                DELETE FROM segment_description
                WHERE segment_id IN (
                    SELECT id FROM segment WHERE asset_id = ? AND is_active = 1
                )
                """
            )
            try deleteDescriptions.bind(.text(assetID), at: 1)
            _ = try deleteDescriptions.step()

            let requeue = try connection.prepare(
                """
                UPDATE job
                SET status = 'pending', checkpoint_json = ?, error_message = NULL, updated_at = ?
                WHERE kind = 'describe_segment'
                  AND status IN ('succeeded', 'failed', 'cancelled')
                  AND segment_id IN (
                    SELECT id FROM segment WHERE asset_id = ? AND is_active = 1
                  )
                """
            )
            try requeue.bind(.text(checkpoint(stage: "requeue")), at: 1)
            try requeue.bind(.real(now.timeIntervalSince1970), at: 2)
            try requeue.bind(.text(assetID), at: 3)
            _ = try requeue.step()
        }
    }

    /// 手动重跑全部配置性过期的描述（prompt/模型变更后的全库刷新入口）。
    public func requeueStaleDescriptions(
        descriptionModelID: String,
        promptVersion: String,
        now: Date = Date()
    ) throws {
        try connection.inTransaction {
            let requeue = try connection.prepare(
                """
                UPDATE job
                SET status = 'pending', checkpoint_json = ?, error_message = NULL, updated_at = ?
                WHERE kind = 'describe_segment'
                  AND status IN ('succeeded', 'failed', 'cancelled')
                  AND segment_id IN (
                    SELECT s.id
                    FROM segment s
                    JOIN media_asset a ON a.id = s.asset_id
                    JOIN segment_description d ON d.segment_id = s.id
                    JOIN derivation_run r ON r.id = d.derivation_run_id
                    WHERE a.status = 'ready'
                      AND a.invalidated_at IS NULL
                      AND a.is_excluded = 0
                      AND s.is_active = 1
                      AND (d.prompt_version <> ? OR r.model_id <> ?)
                )
                """
            )
            try requeue.bind(.text(checkpoint(stage: "requeue")), at: 1)
            try requeue.bind(.real(now.timeIntervalSince1970), at: 2)
            try requeue.bind(.text(promptVersion), at: 3)
            try requeue.bind(.text(descriptionModelID), at: 4)
            _ = try requeue.step()

            let deleteDescriptions = try connection.prepare(
                """
                DELETE FROM segment_description
                WHERE segment_id IN (
                    SELECT s.id
                    FROM segment s
                    JOIN media_asset a ON a.id = s.asset_id
                    JOIN segment_description d ON d.segment_id = s.id
                    JOIN derivation_run r ON r.id = d.derivation_run_id
                    WHERE a.status = 'ready'
                      AND a.invalidated_at IS NULL
                      AND a.is_excluded = 0
                      AND s.is_active = 1
                      AND (d.prompt_version <> ? OR r.model_id <> ?)
                )
                """
            )
            try deleteDescriptions.bind(.text(promptVersion), at: 1)
            try deleteDescriptions.bind(.text(descriptionModelID), at: 2)
            _ = try deleteDescriptions.step()
        }
    }

    public func completeDescribeJob(
        claim: JobClaimToken,
        expectedInputRevision: String,
        now: Date = Date()
    ) throws {
        try connection.inTransaction {
            guard let segmentID = try requireActiveClaim(
                claim,
                kind: .describeSegment
            ) else { throw MediaDatabaseDerivationError.missingTarget }
            try requireDescriptionInputRevision(segmentID: segmentID, expected: expectedInputRevision)
            try finishJob(claim: claim, now: now)
        }
    }

    public func describeProgress() throws -> IndexingProgress {
        try progress(kind: "describe_segment")
    }

    /// 一次取回每个视频的处理进度汇总（片段数、向量数、两类任务的
    /// 各状态计数与当前运行环节），供视频卡片与队列总览使用。
    public func assetProcessingSummaries() throws -> [String: AssetProcessingSummary] {
        var segmentationByAsset: [String: (status: JobStatus, stage: String?)] = [:]
        let segmentationStatement = try connection.prepare(
            """
            SELECT j.asset_id, j.status, j.checkpoint_json
            FROM job j
            JOIN media_asset a ON a.id = j.asset_id
            WHERE j.kind = 'segment_asset'
              AND a.status = 'ready' AND a.invalidated_at IS NULL AND a.is_excluded = 0
            """
        )
        while try segmentationStatement.step(),
              let assetID = segmentationStatement.text(at: 0),
              let statusText = segmentationStatement.text(at: 1),
              let status = JobStatus(rawValue: statusText) {
            segmentationByAsset[assetID] = (
                status: status,
                stage: stage(from: segmentationStatement.text(at: 2))
            )
        }

        var segmentCounts: [String: Int] = [:]
        let segmentStatement = try connection.prepare(
            "SELECT asset_id, count(*) FROM segment WHERE is_active = 1 GROUP BY asset_id"
        )
        while try segmentStatement.step(),
              let assetID = segmentStatement.text(at: 0) {
            segmentCounts[assetID] = Int(segmentStatement.integer(at: 1))
        }

        var embeddingCounts: [String: Int] = [:]
        let embeddingStatement = try connection.prepare(
            """
            SELECT s.asset_id, count(*)
            FROM segment_embedding e
            JOIN segment s ON s.id = e.segment_id
            WHERE s.is_active = 1
            GROUP BY s.asset_id
            """
        )
        while try embeddingStatement.step(),
              let assetID = embeddingStatement.text(at: 0) {
            embeddingCounts[assetID] = Int(embeddingStatement.integer(at: 1))
        }

        struct JobCounts {
            var evidenceSucceeded = 0
            var evidencePending = 0
            var evidenceRunning = false
            var evidenceFailed = 0
            var describeSucceeded = 0
            var describePending = 0
            var describeRunning = false
            var describeFailed = 0
        }
        var jobCountsByAsset: [String: JobCounts] = [:]
        let jobStatement = try connection.prepare(
            """
            SELECT a.id, j.kind, j.status, count(*)
            FROM job j
            JOIN media_asset a ON a.id = j.asset_id
            JOIN segment s ON s.id = j.segment_id
            WHERE a.is_excluded = 0
              AND (
                s.is_active = 1
                OR EXISTS (
                    SELECT 1 FROM derivation_run sr
                    WHERE sr.id = s.segmentation_run_id
                      AND sr.kind = 'segmentation' AND sr.status = 'running'
                )
              )
            GROUP BY a.id, j.kind, j.status
            """
        )
        while try jobStatement.step(),
              let assetID = jobStatement.text(at: 0),
              let kind = jobStatement.text(at: 1),
              let statusText = jobStatement.text(at: 2),
              let status = JobStatus(rawValue: statusText) {
            let count = Int(jobStatement.integer(at: 3))
            var counts = jobCountsByAsset[assetID] ?? JobCounts()
            switch kind {
            case "index_segment":
                switch status {
                case .succeeded: counts.evidenceSucceeded += count
                case .pending: counts.evidencePending += count
                case .running: counts.evidenceRunning = true
                case .failed, .cancelled: counts.evidenceFailed += count
                }
            case "describe_segment":
                switch status {
                case .succeeded: counts.describeSucceeded += count
                case .pending: counts.describePending += count
                case .running: counts.describeRunning = true
                case .failed, .cancelled: counts.describeFailed += count
                }
            default:
                break
            }
            jobCountsByAsset[assetID] = counts
        }

        var runningStageByAsset: [String: (stage: String?, ordinal: Int?)] = [:]
        let runningStatement = try connection.prepare(
            """
            SELECT a.id, s.ordinal, j.checkpoint_json
            FROM job j
            JOIN segment s ON s.id = j.segment_id
            JOIN media_asset a ON a.id = j.asset_id
            WHERE j.status = 'running' AND j.kind = 'index_segment'
            """
        )
        while try runningStatement.step(),
              let assetID = runningStatement.text(at: 0) {
            runningStageByAsset[assetID] = (
                stage: stage(from: runningStatement.text(at: 2)),
                ordinal: Int(runningStatement.integer(at: 1))
            )
        }

        var summaries: [String: AssetProcessingSummary] = [:]
        let assetIDs = Set(segmentCounts.keys)
            .union(jobCountsByAsset.keys)
            .union(segmentationByAsset.keys)
        for assetID in assetIDs {
            let counts = jobCountsByAsset[assetID] ?? JobCounts()
            let running = runningStageByAsset[assetID]
            let segmentation = segmentationByAsset[assetID]
            summaries[assetID] = AssetProcessingSummary(
                assetID: assetID,
                segmentationStatus: segmentation?.status,
                segmentationStage: segmentation?.stage,
                totalSegments: segmentCounts[assetID] ?? 0,
                indexedSegments: embeddingCounts[assetID] ?? 0,
                evidenceSucceeded: counts.evidenceSucceeded,
                evidencePending: counts.evidencePending,
                evidenceRunning: counts.evidenceRunning,
                evidenceFailed: counts.evidenceFailed,
                currentStage: running?.stage,
                currentSegmentOrdinal: running?.ordinal,
                describeSucceeded: counts.describeSucceeded,
                describePending: counts.describePending,
                describeRunning: counts.describeRunning,
                describeFailed: counts.describeFailed
            )
        }
        return summaries
    }

    public func processingSnapshot() throws -> [String: AssetProcessingSummary] {
        try connection.inReadTransaction {
            try assetProcessingSummaries()
        }
    }

    public func jobDashboardSnapshot(
        descriptionModelID: String?,
        promptVersion: String?
    ) throws -> JobDashboardSnapshot {
        try connection.inReadTransaction {
            let staleCount: Int
            if let descriptionModelID, let promptVersion {
                staleCount = try staleDescriptionCount(
                    descriptionModelID: descriptionModelID,
                    promptVersion: promptVersion
                )
            } else {
                staleCount = 0
            }
            return JobDashboardSnapshot(
                jobs: try indexJobs(),
                failures: try failedJobSummaries(),
                indexingProgress: try indexingProgress(),
                describeProgress: try describeProgress(),
                staleDescriptionCount: staleCount,
                processingSummaries: try assetProcessingSummaries()
            )
        }
    }

    public func updateIndexJob(
        claim: JobClaimToken,
        stage: String,
        now: Date = Date()
    ) throws {
        let statement = try connection.prepare(
            """
            UPDATE job SET checkpoint_json = ?, updated_at = ?
            WHERE id = ? AND status = 'running' AND attempt_count = ?
            RETURNING id
            """
        )
        try statement.bind(.text(checkpoint(stage: stage)), at: 1)
        try statement.bind(.real(now.timeIntervalSince1970), at: 2)
        try statement.bind(.text(claim.jobID), at: 3)
        try statement.bind(.integer(Int64(claim.attemptCount)), at: 4)
        guard try statement.step() else { throw MediaDatabaseDerivationError.staleClaim }
    }

    public func returnIndexJobToQueue(
        claim: JobClaimToken,
        stage: String = "paused",
        now: Date = Date()
    ) throws {
        let statement = try connection.prepare(
            """
            UPDATE job
            SET status = 'pending', checkpoint_json = ?, error_message = NULL, updated_at = ?
            WHERE id = ? AND status = 'running' AND attempt_count = ?
            RETURNING id
            """
        )
        try statement.bind(.text(checkpoint(stage: stage)), at: 1)
        try statement.bind(.real(now.timeIntervalSince1970), at: 2)
        try statement.bind(.text(claim.jobID), at: 3)
        try statement.bind(.integer(Int64(claim.attemptCount)), at: 4)
        guard try statement.step() else { throw MediaDatabaseDerivationError.staleClaim }
    }

    public func failIndexJob(
        claim: JobClaimToken,
        message: String,
        now: Date = Date()
    ) throws {
        let statement = try connection.prepare(
            """
            UPDATE job
            SET status = 'failed', checkpoint_json = ?, error_message = ?, updated_at = ?
            WHERE id = ? AND status = 'running' AND attempt_count = ?
            RETURNING id
            """
        )
        try statement.bind(.text(checkpoint(stage: "failed")), at: 1)
        try statement.bind(.text(String(message.prefix(2_000))), at: 2)
        try statement.bind(.real(now.timeIntervalSince1970), at: 3)
        try statement.bind(.text(claim.jobID), at: 4)
        try statement.bind(.integer(Int64(claim.attemptCount)), at: 5)
        guard try statement.step() else { throw MediaDatabaseDerivationError.staleClaim }
    }

    /// 各车道只重试自己的失败任务。
    public func retryFailedJobs(kind: JobKind, now: Date = Date()) throws {
        let statement = try connection.prepare(
            """
            UPDATE job
            SET status = 'pending', checkpoint_json = ?, error_message = NULL, updated_at = ?
            WHERE kind = ? AND status IN ('failed', 'cancelled')
            """
        )
        try statement.bind(.text(checkpoint(stage: "retry_queued")), at: 1)
        try statement.bind(.real(now.timeIntervalSince1970), at: 2)
        try statement.bind(.text(kind.rawValue), at: 3)
        _ = try statement.step()
    }

    public func indexJobs() throws -> [IndexJobRecord] {
        let statement = try connection.prepare(
            """
            SELECT j.id, j.asset_id, j.segment_id, j.status, j.attempt_count,
                   j.checkpoint_json, j.error_message, j.created_at, j.updated_at
            FROM job j
            JOIN segment s ON s.id = j.segment_id
            WHERE j.kind IN ('index_segment', 'describe_segment')
              AND (
                s.is_active = 1
                OR EXISTS (
                    SELECT 1 FROM derivation_run sr
                    WHERE sr.id = s.segmentation_run_id
                      AND sr.kind = 'segmentation' AND sr.status = 'running'
                )
              )
              AND (
                j.status = 'running'
                OR NOT (
                    s.segmentation_run_id IS NULL
                    AND EXISTS (
                        SELECT 1 FROM job sj
                        WHERE sj.asset_id = s.asset_id
                          AND sj.kind = 'segment_asset'
                    )
                )
              )
            ORDER BY j.created_at
            """
        )
        var jobs: [IndexJobRecord] = []
        while try statement.step() {
            guard let id = statement.text(at: 0),
                  let assetID = statement.text(at: 1),
                  let segmentID = statement.text(at: 2),
                  let statusText = statement.text(at: 3),
                  let status = JobStatus(rawValue: statusText) else {
                continue
            }
            jobs.append(
                IndexJobRecord(
                    id: id,
                    assetID: assetID,
                    segmentID: segmentID,
                    status: status,
                    attemptCount: Int(statement.integer(at: 4)),
                    stage: stage(from: statement.text(at: 5)),
                    errorMessage: statement.text(at: 6),
                    createdAt: Date(timeIntervalSince1970: statement.real(at: 7)),
                    updatedAt: Date(timeIntervalSince1970: statement.real(at: 8))
                )
            )
        }
        return jobs
    }

    public func indexingProgress() throws -> IndexingProgress {
        try progress(kind: "index_segment")
    }

    private func progress(kind: String) throws -> IndexingProgress {
        // 只统计仍可处理资产上的任务：被移除/缺失视频上的僵尸任务
        // 不再占用进度，也不应触发车道重启。
        let statement = try connection.prepare(
            """
            SELECT j.status, count(*)
            FROM job j
            JOIN media_asset a ON a.id = j.asset_id
            JOIN segment s ON s.id = j.segment_id
            WHERE j.kind = ?
              AND a.status = 'ready'
              AND a.invalidated_at IS NULL
              AND a.is_excluded = 0
              AND (
                s.is_active = 1
                OR EXISTS (
                    SELECT 1 FROM derivation_run sr
                    WHERE sr.id = s.segmentation_run_id
                      AND sr.kind = 'segmentation' AND sr.status = 'running'
                )
              )
              AND (
                j.status = 'running'
                OR NOT (
                    s.segmentation_run_id IS NULL
                    AND EXISTS (
                        SELECT 1 FROM job sj
                        WHERE sj.asset_id = s.asset_id
                          AND sj.kind = 'segment_asset'
                    )
                )
              )
            GROUP BY j.status
            """
        )
        try statement.bind(.text(kind), at: 1)
        var counts: [JobStatus: Int] = [:]
        while try statement.step(),
              let raw = statement.text(at: 0),
              let status = JobStatus(rawValue: raw) {
            counts[status] = Int(statement.integer(at: 1))
        }
        let pending = counts[.pending, default: 0]
        let running = counts[.running, default: 0]
        let succeeded = counts[.succeeded, default: 0]
        let failed = counts[.failed, default: 0] + counts[.cancelled, default: 0]
        return IndexingProgress(
            total: pending + running + succeeded + failed,
            pending: pending,
            running: running,
            succeeded: succeeded,
            failed: failed
        )
    }

    public func commitIndexOutput(
        claim: JobClaimToken,
        segmentID: String,
        output: SegmentIndexOutput,
        inputVersion: String,
        now: Date = Date()
    ) throws {
        guard output.embedding.dimension > 0 else {
            throw MediaDatabaseDerivationError.invalidVector
        }
        try connection.inTransaction {
            try requireActiveClaim(
                claim,
                kind: .indexSegment,
                expectedSegmentID: segmentID
            )
            let source = try connection.prepare(
                """
                SELECT a.fingerprint
                FROM segment s
                JOIN media_asset a ON a.id = s.asset_id
                WHERE s.id = ? AND a.status = 'ready' AND a.invalidated_at IS NULL AND a.is_excluded = 0
                """
            )
            try source.bind(.text(segmentID), at: 1)
            guard try source.step(), let fingerprint = source.text(at: 0) else {
                throw MediaDatabaseDerivationError.missingTarget
            }
            guard fingerprint == output.sourceFingerprint else {
                throw MediaDatabaseDerivationError.sourceChanged
            }

            let deleteFTS = try connection.prepare("DELETE FROM evidence_fts WHERE segment_id = ?")
            try deleteFTS.bind(.text(segmentID), at: 1)
            _ = try deleteFTS.step()
            for table in ["transcript_segment", "ocr_observation", "segment_frame", "segment_embedding"] {
                let delete = try connection.prepare("DELETE FROM \(table) WHERE segment_id = ?")
                try delete.bind(.text(segmentID), at: 1)
                _ = try delete.step()
            }

            let assetID = try assetID(for: segmentID)
            let asrRunID = try insertRun(
                assetID: assetID,
                kind: "asr",
                modelID: output.asrModelID,
                fingerprint: fingerprint,
                runtimeVersion: output.runtimeVersion,
                now: now
            )
            let alignmentRunID = try insertRun(
                assetID: assetID,
                kind: "alignment",
                modelID: output.alignerModelID,
                fingerprint: fingerprint,
                runtimeVersion: output.runtimeVersion,
                now: now
            )
            let ocrRunID = try insertRun(
                assetID: assetID,
                kind: "ocr",
                modelID: "Apple Vision",
                fingerprint: fingerprint,
                runtimeVersion: ProcessInfo.processInfo.operatingSystemVersionString,
                now: now
            )
            let embeddingRunID = try insertRun(
                assetID: assetID,
                kind: "embedding",
                modelID: output.embeddingModelID,
                fingerprint: fingerprint,
                runtimeVersion: output.runtimeVersion,
                now: now
            )

            for (index, transcript) in output.transcripts.enumerated() {
                // 数据库约束要求 end_ms > start_ms；跳过聚合产生的零时长句子。
                guard transcript.endMS > transcript.startMS else { continue }
                let evidenceID = "\(segmentID):transcript:\(index)"
                let runID = transcript.timingSource == "forced_alignment_sentence"
                    ? alignmentRunID : asrRunID
                let statement = try connection.prepare(
                    """
                    INSERT INTO transcript_segment (
                        id, segment_id, derivation_run_id, text, language,
                        start_ms, end_ms, timing_source
                    ) VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                    """
                )
                let values: [SQLiteValue] = [
                    .text(evidenceID), .text(segmentID), .text(runID), .text(transcript.text),
                    transcript.language.map(SQLiteValue.text) ?? .null,
                    .integer(transcript.startMS), .integer(transcript.endMS),
                    .text(transcript.timingSource)
                ]
                try bind(values, to: statement)
                _ = try statement.step()
                try insertFTS(
                    segmentID: segmentID,
                    type: "transcript",
                    evidenceID: evidenceID,
                    text: transcript.text
                )
            }

            for (index, observation) in output.ocr.enumerated() {
                let evidenceID = "\(segmentID):ocr:\(index)"
                let statement = try connection.prepare(
                    """
                    INSERT INTO ocr_observation (
                        id, segment_id, derivation_run_id, text, confidence,
                        box_x, box_y, box_width, box_height, start_ms, end_ms
                    ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    """
                )
                let values: [SQLiteValue] = [
                    .text(evidenceID), .text(segmentID), .text(ocrRunID), .text(observation.text),
                    .real(Double(observation.confidence)), .real(observation.boxX),
                    .real(observation.boxY), .real(observation.boxWidth),
                    .real(observation.boxHeight), .integer(observation.startMS),
                    .integer(observation.endMS)
                ]
                try bind(values, to: statement)
                _ = try statement.step()
                try insertFTS(
                    segmentID: segmentID,
                    type: "ocr",
                    evidenceID: evidenceID,
                    text: observation.text
                )
            }

            for (index, frame) in output.frames.enumerated() {
                let statement = try connection.prepare(
                    """
                    INSERT INTO segment_frame (
                        id, segment_id, ordinal, time_ms, relative_path,
                        perceptual_hash, created_at
                    ) VALUES (?, ?, ?, ?, ?, ?, ?)
                    """
                )
                let values: [SQLiteValue] = [
                    .text("\(segmentID):frame:\(index)"), .text(segmentID),
                    .integer(Int64(index)), .integer(frame.timeMS), .text(frame.relativePath),
                    .integer(Int64(bitPattern: frame.perceptualHash)),
                    .real(now.timeIntervalSince1970)
                ]
                try bind(values, to: statement)
                _ = try statement.step()
            }

            let embedding = try connection.prepare(
                """
                INSERT INTO segment_embedding (
                    segment_id, derivation_run_id, dimension, vector,
                    model_id, input_version, created_at
                ) VALUES (?, ?, ?, ?, ?, ?, ?)
                """
            )
            let embeddingValues: [SQLiteValue] = [
                .text(segmentID), .text(embeddingRunID),
                .integer(Int64(output.embedding.dimension)),
                .blob(vectorData(output.embedding.values)),
                .text(output.embeddingModelID), .text(inputVersion),
                .real(now.timeIntervalSince1970)
            ]
            try bind(embeddingValues, to: embedding)
            _ = try embedding.step()

            let finish = try connection.prepare(
                """
                UPDATE job
                SET status = 'succeeded', checkpoint_json = ?, error_message = NULL, updated_at = ?
                WHERE id = ? AND status = 'running' AND attempt_count = ?
                RETURNING id
                """
            )
            try finish.bind(.text(checkpoint(stage: "complete")), at: 1)
            try finish.bind(.real(now.timeIntervalSince1970), at: 2)
            try finish.bind(.text(claim.jobID), at: 3)
            try finish.bind(.integer(Int64(claim.attemptCount)), at: 4)
            guard try finish.step() else { throw MediaDatabaseDerivationError.staleClaim }
        }
    }

    public func literalSearch(query: String, limit: Int = 50) throws -> [LiteralSearchMatch] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        let useFTS = trimmed.count >= 3
        let statement = try connection.prepare(
            """
            SELECT f.segment_id, f.evidence_type, f.evidence_id, f.text,
                   CASE f.evidence_type
                       WHEN 'transcript' THEN t.start_ms
                       WHEN 'ocr' THEN o.start_ms
                       ELSE s.start_ms
                   END,
                   CASE f.evidence_type
                       WHEN 'transcript' THEN t.end_ms
                       WHEN 'ocr' THEN o.end_ms
                       ELSE s.end_ms
                   END,
                   \(useFTS ? "bm25(evidence_fts)" : "0.0")
            FROM evidence_fts f
            JOIN segment s ON s.id = f.segment_id
            JOIN media_asset a ON a.id = s.asset_id
            LEFT JOIN transcript_segment t
                ON f.evidence_type = 'transcript' AND t.id = f.evidence_id
            LEFT JOIN ocr_observation o
                ON f.evidence_type = 'ocr' AND o.id = f.evidence_id
            WHERE a.status = 'ready' AND a.invalidated_at IS NULL AND a.is_excluded = 0
              AND (
                s.is_active = 1
                OR (
                    f.evidence_type = 'visual'
                    AND s.is_active = 0
                    AND s.segmentation_version = (
                        SELECT max(previous.segmentation_version)
                        FROM segment previous
                        JOIN evidence_fts previous_fts
                          ON previous_fts.segment_id = previous.id
                         AND previous_fts.evidence_type = 'visual'
                        WHERE previous.asset_id = s.asset_id
                          AND previous.is_active = 0
                    )
                    AND EXISTS (
                        SELECT 1
                        FROM segment current
                        WHERE current.asset_id = s.asset_id
                          AND current.is_active = 1
                          AND NOT EXISTS (
                            SELECT 1 FROM segment_description current_description
                            WHERE current_description.segment_id = current.id
                          )
                    )
                )
              )
              AND \(useFTS ? "evidence_fts MATCH ?" : "instr(lower(f.text), lower(?)) > 0")
            ORDER BY \(useFTS ? "bm25(evidence_fts)" : "f.rowid DESC")
            LIMIT ?
            """
        )
        let escaped = trimmed.replacingOccurrences(of: "\"", with: "\"\"")
        try statement.bind(.text(useFTS ? "\"\(escaped)\"" : trimmed), at: 1)
        try statement.bind(.integer(Int64(max(1, limit))), at: 2)
        var results: [LiteralSearchMatch] = []
        while try statement.step() {
            guard let segmentID = statement.text(at: 0),
                  let type = statement.text(at: 1),
                  let kind = SearchEvidenceKind(rawValue: type),
                  let evidenceID = statement.text(at: 2),
                  let text = statement.text(at: 3) else {
                continue
            }
            results.append(
                LiteralSearchMatch(
                    segmentID: segmentID,
                    evidence: SearchEvidence(
                        id: evidenceID,
                        kind: kind,
                        text: text,
                        startMS: statement.integer(at: 4),
                        endMS: statement.integer(at: 5)
                    ),
                    rank: statement.real(at: 6)
                )
            )
        }
        return results
    }

    public func storedEmbeddings(modelID: String, inputVersion: String) throws -> [StoredEmbedding] {
        let statement = try connection.prepare(
            """
            SELECT e.segment_id, e.dimension, e.vector
            FROM segment_embedding e
            JOIN segment s ON s.id = e.segment_id
            JOIN media_asset a ON a.id = s.asset_id
            WHERE e.model_id = ? AND e.input_version = ?
              AND a.status = 'ready' AND a.invalidated_at IS NULL AND a.is_excluded = 0
              AND s.is_active = 1
            ORDER BY e.segment_id
            """
        )
        try statement.bind(.text(modelID), at: 1)
        try statement.bind(.text(inputVersion), at: 2)
        var records: [StoredEmbedding] = []
        while try statement.step() {
            guard let segmentID = statement.text(at: 0),
                  let data = statement.blob(at: 2) else { continue }
            let dimension = Int(statement.integer(at: 1))
            let values = decodeVector(data)
            guard values.count == dimension else {
                throw MediaDatabaseDerivationError.invalidVector
            }
            records.append(StoredEmbedding(segmentID: segmentID, values: values))
        }
        return records
    }

    public func embeddingIndexRevision(modelID: String, inputVersion: String) throws -> String {
        let statement = try connection.prepare(
            """
            SELECT count(*), coalesce(max(e.created_at), 0), coalesce(sum(e.rowid), 0)
            FROM segment_embedding e
            JOIN segment s ON s.id = e.segment_id
            JOIN media_asset a ON a.id = s.asset_id
            WHERE e.model_id = ? AND e.input_version = ?
              AND a.status = 'ready' AND a.invalidated_at IS NULL AND a.is_excluded = 0
              AND s.is_active = 1
            """
        )
        try statement.bind(.text(modelID), at: 1)
        try statement.bind(.text(inputVersion), at: 2)
        guard try statement.step() else { return "0:0:0" }
        return "\(statement.integer(at: 0)):\(String(format: "%.17g", statement.real(at: 1))):\(statement.integer(at: 2))"
    }

    public func searchContext(segmentID: String) throws -> SegmentSearchContext? {
        let target = try connection.prepare(
            """
            SELECT a.id, a.root_id, a.relative_path, a.standardized_path,
                   a.file_size, a.modification_time, a.duration_ms,
                   a.video_track_count, a.audio_track_count, a.is_playable,
                   a.fingerprint, a.status, a.error_message,
                   a.first_seen_at, a.last_seen_at,
                   s.id, s.asset_id, s.ordinal, s.start_ms, s.end_ms,
                   s.segmentation_version
            FROM segment s
            JOIN media_asset a ON a.id = s.asset_id
            WHERE s.id = ?
              AND (
                s.is_active = 1
                OR (
                    s.is_active = 0
                    AND EXISTS (
                        SELECT 1 FROM evidence_fts old_visual
                        WHERE old_visual.segment_id = s.id
                          AND old_visual.evidence_type = 'visual'
                    )
                    AND s.segmentation_version = (
                        SELECT max(previous.segmentation_version)
                        FROM segment previous
                        JOIN evidence_fts previous_fts
                          ON previous_fts.segment_id = previous.id
                         AND previous_fts.evidence_type = 'visual'
                        WHERE previous.asset_id = s.asset_id
                          AND previous.is_active = 0
                    )
                    AND EXISTS (
                        SELECT 1
                        FROM segment current
                        WHERE current.asset_id = s.asset_id
                          AND current.is_active = 1
                          AND NOT EXISTS (
                            SELECT 1 FROM segment_description current_description
                            WHERE current_description.segment_id = current.id
                          )
                    )
                )
              )
              AND a.status = 'ready' AND a.invalidated_at IS NULL AND a.is_excluded = 0
            """
        )
        try target.bind(.text(segmentID), at: 1)
        guard try target.step(),
              let asset = assetRecord(from: target, offset: 0),
              let segment = segmentRecord(from: target, offset: 15) else {
            return nil
        }
        return SegmentSearchContext(
            segment: segment,
            asset: asset,
            evidence: try evidence(segmentID: segmentID)
        )
    }

    public func segmentFrames(segmentID: String) throws -> [SegmentFrameRecord] {
        let statement = try connection.prepare(
            """
            SELECT id, segment_id, ordinal, time_ms, relative_path, perceptual_hash
            FROM segment_frame WHERE segment_id = ? ORDER BY ordinal
            """
        )
        try statement.bind(.text(segmentID), at: 1)
        var frames: [SegmentFrameRecord] = []
        while try statement.step() {
            guard let id = statement.text(at: 0),
                  let storedSegmentID = statement.text(at: 1),
                  let path = statement.text(at: 4) else { continue }
            frames.append(
                SegmentFrameRecord(
                    id: id,
                    segmentID: storedSegmentID,
                    ordinal: Int(statement.integer(at: 2)),
                    timeMS: statement.integer(at: 3),
                    relativePath: path,
                    perceptualHash: UInt64(bitPattern: statement.integer(at: 5))
                )
            )
        }
        return frames
    }

    public func referencedFrameRelativePaths() throws -> Set<String> {
        let statement = try connection.prepare("SELECT relative_path FROM segment_frame")
        var paths = Set<String>()
        while try statement.step() {
            if let path = statement.text(at: 0) { paths.insert(path) }
        }
        return paths
    }

    public func cachedDescription(
        segmentID: String,
        inputVersion: String
    ) throws -> CachedSegmentDescription? {
        let statement = try connection.prepare(
            """
            SELECT description_json, input_version, created_at, d.prompt_version,
                   coalesce(r.model_id, '')
            FROM segment_description d
            LEFT JOIN derivation_run r ON r.id = d.derivation_run_id
            WHERE d.segment_id = ? AND d.input_version = ?
            """
        )
        try statement.bind(.text(segmentID), at: 1)
        try statement.bind(.text(inputVersion), at: 2)
        guard try statement.step(), let json = statement.text(at: 0) else { return nil }
        let description = try JSONDecoder().decode(
            SegmentDescription.self,
            from: Data(json.utf8)
        )
        return CachedSegmentDescription(
            description: description,
            inputVersion: statement.text(at: 1) ?? inputVersion,
            promptVersion: statement.text(at: 3) ?? "",
            modelID: statement.text(at: 4) ?? "",
            createdAt: Date(timeIntervalSince1970: statement.real(at: 2))
        )
    }

    /// 展示用：片段最新一份缓存描述（无论 input/prompt/模型版本是否当前）。
    public func latestDescription(segmentID: String) throws -> CachedSegmentDescription? {
        let statement = try connection.prepare(
            """
            SELECT description_json, input_version, created_at, d.prompt_version,
                   coalesce(r.model_id, '')
            FROM segment_description d
            LEFT JOIN derivation_run r ON r.id = d.derivation_run_id
            WHERE d.segment_id = ?
            ORDER BY d.created_at DESC
            LIMIT 1
            """
        )
        try statement.bind(.text(segmentID), at: 1)
        guard try statement.step(), let json = statement.text(at: 0) else { return nil }
        let description = try JSONDecoder().decode(
            SegmentDescription.self,
            from: Data(json.utf8)
        )
        return CachedSegmentDescription(
            description: description,
            inputVersion: statement.text(at: 1) ?? "",
            promptVersion: statement.text(at: 3) ?? "",
            modelID: statement.text(at: 4) ?? "",
            createdAt: Date(timeIntervalSince1970: statement.real(at: 2))
        )
    }

    /// 展示整个视频时一次取回全部片段描述，避免详情页按片段逐条查询。
    public func latestDescriptions(assetID: String) throws -> [String: CachedSegmentDescription] {
        let statement = try connection.prepare(
            """
            SELECT d.segment_id, d.description_json, d.input_version, d.created_at,
                   d.prompt_version, coalesce(r.model_id, '')
            FROM segment_description d
            JOIN segment s ON s.id = d.segment_id
            LEFT JOIN derivation_run r ON r.id = d.derivation_run_id
            WHERE s.asset_id = ? AND s.is_active = 1
            """
        )
        try statement.bind(.text(assetID), at: 1)
        var descriptions: [String: CachedSegmentDescription] = [:]
        while try statement.step() {
            guard let segmentID = statement.text(at: 0),
                  let json = statement.text(at: 1) else { continue }
            let description = try JSONDecoder().decode(
                SegmentDescription.self,
                from: Data(json.utf8)
            )
            descriptions[segmentID] = CachedSegmentDescription(
                description: description,
                inputVersion: statement.text(at: 2) ?? "",
                promptVersion: statement.text(at: 4) ?? "",
                modelID: statement.text(at: 5) ?? "",
                createdAt: Date(timeIntervalSince1970: statement.real(at: 3))
            )
        }
        return descriptions
    }

    public func saveDescription(
        segmentID: String,
        sourceFingerprint: String,
        expectedInputRevision: String,
        modelID: String,
        runtimeVersion: String,
        promptVersion: String,
        inputVersion: String,
        description: SegmentDescription,
        now: Date = Date()
    ) throws {
        let jsonData = try JSONEncoder().encode(description)
        let json = String(decoding: jsonData, as: UTF8.self)
        try connection.inTransaction {
            try persistDescription(
                segmentID: segmentID,
                sourceFingerprint: sourceFingerprint,
                expectedInputRevision: expectedInputRevision,
                modelID: modelID,
                runtimeVersion: runtimeVersion,
                promptVersion: promptVersion,
                inputVersion: inputVersion,
                description: description,
                json: json,
                now: now
            )
        }
    }

    /// 描述车道的唯一提交入口：校验 claim 与证据 revision 后，
    /// 在同一事务内保存描述并完成任务。
    public func commitDescription(
        claim: JobClaimToken,
        segmentID: String,
        sourceFingerprint: String,
        expectedInputRevision: String,
        modelID: String,
        runtimeVersion: String,
        promptVersion: String,
        inputVersion: String,
        description: SegmentDescription,
        now: Date = Date()
    ) throws {
        let jsonData = try JSONEncoder().encode(description)
        let json = String(decoding: jsonData, as: UTF8.self)
        try connection.inTransaction {
            try requireActiveClaim(
                claim,
                kind: .describeSegment,
                expectedSegmentID: segmentID
            )
            try persistDescription(
                segmentID: segmentID,
                sourceFingerprint: sourceFingerprint,
                expectedInputRevision: expectedInputRevision,
                modelID: modelID,
                runtimeVersion: runtimeVersion,
                promptVersion: promptVersion,
                inputVersion: inputVersion,
                description: description,
                json: json,
                now: now
            )
            try finishJob(claim: claim, now: now)
        }
    }

    /// 当前描述输入所对应的原子证据提交 revision。
    public func descriptionInputRevision(segmentID: String) throws -> String? {
        let statement = try connection.prepare(
            """
            SELECT e.derivation_run_id
            FROM segment_embedding e
            JOIN segment s ON s.id = e.segment_id
            JOIN media_asset a ON a.id = s.asset_id
            WHERE s.id = ? AND a.status = 'ready'
              AND a.invalidated_at IS NULL AND a.is_excluded = 0
            """
        )
        try statement.bind(.text(segmentID), at: 1)
        return try statement.step() ? statement.text(at: 0) : nil
    }

    private func persistDescription(
        segmentID: String,
        sourceFingerprint: String,
        expectedInputRevision: String,
        modelID: String,
        runtimeVersion: String,
        promptVersion: String,
        inputVersion: String,
        description: SegmentDescription,
        json: String,
        now: Date
    ) throws {
        let source = try connection.prepare(
            """
            SELECT a.id, a.fingerprint, e.derivation_run_id
            FROM segment s
            JOIN media_asset a ON a.id = s.asset_id
            JOIN segment_embedding e ON e.segment_id = s.id
            WHERE s.id = ? AND a.status = 'ready'
              AND a.invalidated_at IS NULL AND a.is_excluded = 0
            """
        )
        try source.bind(.text(segmentID), at: 1)
        guard try source.step(),
              let assetID = source.text(at: 0),
              let fingerprint = source.text(at: 1),
              let currentInputRevision = source.text(at: 2) else {
            throw MediaDatabaseDerivationError.missingTarget
        }
        guard fingerprint == sourceFingerprint else {
            throw MediaDatabaseDerivationError.sourceChanged
        }
        guard currentInputRevision == expectedInputRevision else {
            throw MediaDatabaseDerivationError.descriptionInputChanged
        }
        let parametersData = try JSONSerialization.data(withJSONObject: [
            "prompt_version": promptVersion,
            "input_revision": expectedInputRevision
        ])
        let runID = try insertRun(
            assetID: assetID,
            kind: "description",
            modelID: modelID,
            fingerprint: fingerprint,
            runtimeVersion: runtimeVersion,
            parametersJSON: String(decoding: parametersData, as: UTF8.self),
            now: now
        )
        let statement = try connection.prepare(
            """
            INSERT INTO segment_description (
                segment_id, derivation_run_id, description_json,
                prompt_version, input_version, created_at
            ) VALUES (?, ?, ?, ?, ?, ?)
            ON CONFLICT(segment_id) DO UPDATE SET
                derivation_run_id = excluded.derivation_run_id,
                description_json = excluded.description_json,
                prompt_version = excluded.prompt_version,
                input_version = excluded.input_version,
                created_at = excluded.created_at
            """
        )
        let values: [SQLiteValue] = [
            .text(segmentID), .text(runID), .text(json), .text(promptVersion),
            .text(inputVersion), .real(now.timeIntervalSince1970)
        ]
        try bind(values, to: statement)
        _ = try statement.step()
        try replaceVisualDescriptionFTS(segmentID: segmentID, description: description)
    }

    @discardableResult
    private func requireActiveClaim(
        _ claim: JobClaimToken,
        kind: JobKind,
        expectedSegmentID: String? = nil
    ) throws -> String? {
        let statement = try connection.prepare(
            """
            SELECT segment_id FROM job
            WHERE id = ? AND kind = ? AND status = 'running' AND attempt_count = ?
            """
        )
        try statement.bind(.text(claim.jobID), at: 1)
        try statement.bind(.text(kind.rawValue), at: 2)
        try statement.bind(.integer(Int64(claim.attemptCount)), at: 3)
        guard try statement.step() else {
            throw MediaDatabaseDerivationError.staleClaim
        }
        let segmentID = statement.text(at: 0)
        if let expectedSegmentID, segmentID != expectedSegmentID {
            throw MediaDatabaseDerivationError.staleClaim
        }
        return segmentID
    }

    private func requireDescriptionInputRevision(
        segmentID: String,
        expected: String
    ) throws {
        guard let current = try descriptionInputRevision(segmentID: segmentID) else {
            throw MediaDatabaseDerivationError.missingTarget
        }
        guard current == expected else {
            throw MediaDatabaseDerivationError.descriptionInputChanged
        }
    }

    private func finishJob(claim: JobClaimToken, now: Date) throws {
        let statement = try connection.prepare(
            """
            UPDATE job
            SET status = 'succeeded', checkpoint_json = ?, error_message = NULL, updated_at = ?
            WHERE id = ? AND status = 'running' AND attempt_count = ?
            RETURNING id
            """
        )
        try statement.bind(.text(checkpoint(stage: "complete")), at: 1)
        try statement.bind(.real(now.timeIntervalSince1970), at: 2)
        try statement.bind(.text(claim.jobID), at: 3)
        try statement.bind(.integer(Int64(claim.attemptCount)), at: 4)
        guard try statement.step() else { throw MediaDatabaseDerivationError.staleClaim }
    }

    private func evidence(segmentID: String) throws -> [SearchEvidence] {
        let statement = try connection.prepare(
            """
            SELECT id, 'transcript', text, start_ms, end_ms
            FROM transcript_segment WHERE segment_id = ?
            UNION ALL
            SELECT id, 'ocr', text, start_ms, end_ms
            FROM ocr_observation WHERE segment_id = ?
            ORDER BY 4, 2
            """
        )
        try statement.bind(.text(segmentID), at: 1)
        try statement.bind(.text(segmentID), at: 2)
        var rows: [SearchEvidence] = []
        while try statement.step() {
            guard let id = statement.text(at: 0),
                  let rawKind = statement.text(at: 1),
                  let kind = SearchEvidenceKind(rawValue: rawKind),
                  let text = statement.text(at: 2) else { continue }
            rows.append(
                SearchEvidence(
                    id: id,
                    kind: kind,
                    text: text,
                    startMS: statement.integer(at: 3),
                    endMS: statement.integer(at: 4)
                )
            )
        }
        return rows
    }

    private func replaceVisualDescriptionFTS(
        segmentID: String,
        description: SegmentDescription
    ) throws {
        let delete = try connection.prepare(
            "DELETE FROM evidence_fts WHERE segment_id = ? AND evidence_type = 'visual'"
        )
        try delete.bind(.text(segmentID), at: 1)
        _ = try delete.step()

        for (index, text) in description.searchableVisualTexts.enumerated() {
            try insertFTS(
                segmentID: segmentID,
                type: SearchEvidenceKind.visual.rawValue,
                evidenceID: "\(segmentID):visual:\(index)",
                text: text
            )
        }
    }

    private func insertFTS(
        segmentID: String,
        type: String,
        evidenceID: String,
        text: String
    ) throws {
        let statement = try connection.prepare(
            """
            INSERT INTO evidence_fts (segment_id, evidence_type, evidence_id, text)
            VALUES (?, ?, ?, ?)
            """
        )
        try bind(
            [.text(segmentID), .text(type), .text(evidenceID), .text(text)],
            to: statement
        )
        _ = try statement.step()
    }

    private func insertRun(
        assetID: String,
        kind: String,
        modelID: String,
        fingerprint: String,
        runtimeVersion: String,
        parametersJSON: String = "{}",
        now: Date
    ) throws -> String {
        let id = UUID().uuidString
        let statement = try connection.prepare(
            """
            INSERT INTO derivation_run (
                id, asset_id, kind, model_id, model_sha, runtime_version,
                parameters_json, source_fingerprint, status, started_at,
                completed_at, error_message
            ) VALUES (?, ?, ?, ?, NULL, ?, ?, ?, 'succeeded', ?, ?, NULL)
            """
        )
        let values: [SQLiteValue] = [
            .text(id), .text(assetID), .text(kind), .text(modelID),
            .text(runtimeVersion), .text(parametersJSON), .text(fingerprint),
            .real(now.timeIntervalSince1970), .real(now.timeIntervalSince1970)
        ]
        try bind(values, to: statement)
        _ = try statement.step()
        return id
    }

    private func assetID(for segmentID: String) throws -> String {
        let statement = try connection.prepare("SELECT asset_id FROM segment WHERE id = ?")
        try statement.bind(.text(segmentID), at: 1)
        guard try statement.step(), let assetID = statement.text(at: 0) else {
            throw MediaDatabaseDerivationError.missingTarget
        }
        return assetID
    }

    private func bind(_ values: [SQLiteValue], to statement: SQLiteStatement) throws {
        for (index, value) in values.enumerated() {
            try statement.bind(value, at: Int32(index + 1))
        }
    }

    private func assetRecord(from statement: SQLiteStatement, offset: Int32) -> MediaAssetRecord? {
        guard let id = statement.text(at: offset),
              let rootID = statement.text(at: offset + 1),
              let relativePath = statement.text(at: offset + 2),
              let standardizedPath = statement.text(at: offset + 3),
              let fingerprint = statement.text(at: offset + 10),
              let rawStatus = statement.text(at: offset + 11),
              let status = MediaAssetStatus(rawValue: rawStatus) else { return nil }
        return MediaAssetRecord(
            id: id,
            rootID: rootID,
            relativePath: relativePath,
            standardizedPath: standardizedPath,
            fileSize: statement.integer(at: offset + 4),
            modificationDate: Date(timeIntervalSince1970: statement.real(at: offset + 5)),
            durationMS: statement.integer(at: offset + 6),
            videoTrackCount: Int(statement.integer(at: offset + 7)),
            audioTrackCount: Int(statement.integer(at: offset + 8)),
            isPlayable: statement.integer(at: offset + 9) != 0,
            fingerprint: fingerprint,
            status: status,
            errorMessage: statement.text(at: offset + 12),
            firstSeenAt: Date(timeIntervalSince1970: statement.real(at: offset + 13)),
            lastSeenAt: Date(timeIntervalSince1970: statement.real(at: offset + 14))
        )
    }

    private func segmentRecord(from statement: SQLiteStatement, offset: Int32) -> SegmentRecord? {
        guard let id = statement.text(at: offset),
              let assetID = statement.text(at: offset + 1) else { return nil }
        return SegmentRecord(
            id: id,
            assetID: assetID,
            ordinal: Int(statement.integer(at: offset + 2)),
            startMS: statement.integer(at: offset + 3),
            endMS: statement.integer(at: offset + 4),
            segmentationVersion: Int(statement.integer(at: offset + 5))
        )
    }

    private func vectorData(_ values: [Float]) -> Data {
        values.withUnsafeBytes { Data($0) }
    }

    private func decodeVector(_ data: Data) -> [Float] {
        guard data.count.isMultiple(of: MemoryLayout<Float>.size) else { return [] }
        var values = [Float](
            repeating: 0,
            count: data.count / MemoryLayout<Float>.size
        )
        _ = values.withUnsafeMutableBytes { destination in
            data.copyBytes(to: destination)
        }
        return values
    }

    private func checkpoint(stage: String) -> String {
        let data = try? JSONSerialization.data(withJSONObject: ["stage": stage])
        return data.map { String(decoding: $0, as: UTF8.self) } ?? "{}"
    }

    private func stage(from checkpoint: String?) -> String? {
        guard let checkpoint,
              let data = checkpoint.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: String]
        else { return nil }
        return object["stage"]
    }
}
