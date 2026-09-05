import Foundation

public enum SegmentationDatabaseError: Error, LocalizedError, Equatable, Sendable {
    case invalidCoverage
    case staleClaim
    case missingAsset

    public var errorDescription: String? {
        switch self {
        case .invalidCoverage:
            "语义片段没有连续、完整地覆盖源视频时间轴。"
        case .staleClaim:
            "分片任务认领已经失效；陈旧结果已丢弃。"
        case .missingAsset:
            "待分片视频已经不存在或源文件版本已经变化。"
        }
    }
}

extension MediaDatabase {
    /// 仅 reconcile 视频配方的兼容入口：映射为"只有视频一种配方"。
    /// 图片资产存在的库必须走 `algorithmVersionByKind:` 全量入口。
    public func reconcileSegmentationJobs(
        algorithmVersion: String,
        now: Date = Date()
    ) throws -> IndexingProgress {
        try reconcileSegmentationJobs(
            algorithmVersionByKind: [.video: algorithmVersion],
            now: now
        )
    }

    /// 每种媒体类型按各自的算法身份 reconcile：视频与图片的算法版本独立
    /// 演进，互不触发对方的重新分片。每个类型一个事务，互相独立提交。
    public func reconcileSegmentationJobs(
        algorithmVersionByKind: [MediaKind: String],
        now: Date = Date()
    ) throws -> IndexingProgress {
        for kind in MediaKind.allCases {
            guard let algorithmVersion = algorithmVersionByKind[kind] else { continue }
            try reconcileSegmentationJobs(
                forKind: kind,
                algorithmVersion: algorithmVersion,
                now: now
            )
        }
        return try segmentationProgress()
    }

    private func reconcileSegmentationJobs(
        forKind kind: MediaKind,
        algorithmVersion: String,
        now: Date
    ) throws {
        try connection.inTransaction {
            let reset = try connection.prepare(
                """
                UPDATE job
                SET status = 'pending',
                    checkpoint_json = json_set(
                        ?, '$.source_fingerprint',
                        (SELECT fingerprint FROM media_asset WHERE id = job.asset_id)
                    ),
                    error_message = NULL, updated_at = ?
                WHERE kind = 'segment_asset'
                  AND status <> 'running'
                  AND (
                    status IN ('succeeded', 'cancelled')
                    OR coalesce(
                        json_extract(checkpoint_json, '$.algorithm_version'),
                        ''
                    ) <> ?
                    OR coalesce(
                        json_extract(checkpoint_json, '$.source_fingerprint'),
                        ''
                    ) <> coalesce(
                        (SELECT fingerprint FROM media_asset WHERE id = job.asset_id),
                        ''
                    )
                  )
                  AND asset_id IN (
                      SELECT a.id
                      FROM media_asset a
                      WHERE a.status = 'ready'
                        AND a.invalidated_at IS NULL
                        AND a.is_excluded = 0
                        AND a.media_kind = ?
                        AND (
                            a.candidate_duration_ms IS NOT NULL
                            OR NOT EXISTS (
                                SELECT 1
                                FROM derivation_run r
                                WHERE r.asset_id = a.id
                                  AND r.kind = 'segmentation'
                                  AND r.source_fingerprint = a.fingerprint
                                  AND json_extract(r.parameters_json, '$.algorithm_version') = ?
                                  AND r.status IN ('running', 'succeeded')
                            )
                        )
                  )
                """
            )
            try reset.bind(
                .text(segmentationCheckpoint(
                    stage: "queued",
                    algorithmVersion: algorithmVersion,
                    sourceFingerprint: nil
                )),
                at: 1
            )
            try reset.bind(.real(now.timeIntervalSince1970), at: 2)
            try reset.bind(.text(algorithmVersion), at: 3)
            try reset.bind(.text(kind.rawValue), at: 4)
            try reset.bind(.text(algorithmVersion), at: 5)
            _ = try reset.step()

            let enqueue = try connection.prepare(
                """
                INSERT OR IGNORE INTO job (
                    id, asset_id, segment_id, kind, status, attempt_count,
                    checkpoint_json, error_message, created_at, updated_at
                )
                SELECT lower(hex(randomblob(16))), a.id, NULL,
                       'segment_asset', 'pending', 0,
                       json_set(?, '$.source_fingerprint', a.fingerprint), NULL, ?, ?
                FROM media_asset a
                LEFT JOIN job j
                  ON j.asset_id = a.id
                 AND j.kind = 'segment_asset'
                 AND j.segment_id IS NULL
                WHERE a.status = 'ready'
                  AND a.invalidated_at IS NULL
                  AND a.is_excluded = 0
                  AND a.media_kind = ?
                  AND j.id IS NULL
                  AND (
                      a.candidate_duration_ms IS NOT NULL
                      OR NOT EXISTS (
                          SELECT 1
                          FROM derivation_run r
                          WHERE r.asset_id = a.id
                            AND r.kind = 'segmentation'
                            AND r.source_fingerprint = a.fingerprint
                            AND json_extract(r.parameters_json, '$.algorithm_version') = ?
                            AND r.status IN ('running', 'succeeded')
                      )
                  )
                """
            )
            try enqueue.bind(
                .text(segmentationCheckpoint(
                    stage: "queued",
                    algorithmVersion: algorithmVersion,
                    sourceFingerprint: nil
                )),
                at: 1
            )
            try enqueue.bind(.real(now.timeIntervalSince1970), at: 2)
            try enqueue.bind(.real(now.timeIntervalSince1970), at: 3)
            try enqueue.bind(.text(kind.rawValue), at: 4)
            try enqueue.bind(.text(algorithmVersion), at: 5)
            _ = try enqueue.step()

            // Once semantic segmentation owns an asset, pending work for its
            // fixed-range compatibility generation is intentionally
            // unclaimable. Delete those jobs now so progress and scheduling
            // observe the same queue instead of repeatedly starting an idle
            // model lane while content analysis is still running or failed.
            let removePendingLegacyJobs = try connection.prepare(
                """
                DELETE FROM job
                WHERE kind IN ('index_segment', 'describe_segment')
                  AND status = 'pending'
                  AND segment_id IN (
                    SELECT s.id
                    FROM segment s
                    WHERE s.segmentation_run_id IS NULL
                      AND EXISTS (
                        SELECT 1 FROM job sj
                        WHERE sj.asset_id = s.asset_id
                          AND sj.kind = 'segment_asset'
                      )
                  )
                """
            )
            _ = try removePendingLegacyJobs.step()

            // A newly scanned asset has no searchable V1 evidence to preserve.
            // Remove its scan-time compatibility ranges as soon as semantic
            // segmentation owns the asset, so fixed 20-second ranges are never
            // presented or sent into the model pipeline. If any old embedding
            // exists, keep the complete V1 generation until atomic V2 cutover.
            let removeEmptyFallback = try connection.prepare(
                """
                DELETE FROM segment
                WHERE segmentation_run_id IS NULL
                  AND asset_id IN (
                    SELECT a.id
                    FROM media_asset a
                    WHERE a.status = 'ready'
                      AND a.invalidated_at IS NULL
                      AND a.is_excluded = 0
                      AND EXISTS (
                        SELECT 1 FROM job sj
                        WHERE sj.asset_id = a.id AND sj.kind = 'segment_asset'
                      )
                      AND NOT EXISTS (
                        SELECT 1
                        FROM segment_embedding e
                        JOIN segment existing ON existing.id = e.segment_id
                        WHERE existing.asset_id = a.id
                      )
                  )
                """
            )
            _ = try removeEmptyFallback.step()
        }
    }

    public func claimNextSegmentationJob(
        restrictToAssetID: String? = nil,
        now: Date = Date()
    ) throws -> AssetSegmentationClaim {
        try connection.inTransaction {
            guard let activeAssetID = try restrictToAssetID ?? activeProcessingAssetID() else {
                return .idle
            }
            let query = try connection.prepare(
                """
                SELECT j.id, j.attempt_count, j.created_at,
                       a.id, a.root_id, a.relative_path, a.standardized_path,
                       a.file_size, a.modification_time, a.duration_ms,
                       a.video_track_count, a.audio_track_count, a.is_playable,
                       a.fingerprint, a.status, a.error_message,
                       a.first_seen_at, a.last_seen_at, a.candidate_duration_ms,
                       a.media_kind, a.pixel_width, a.pixel_height
                FROM job j
                JOIN media_asset a ON a.id = j.asset_id
                WHERE j.kind = 'segment_asset'
                  AND j.status = 'pending'
                  AND a.status = 'ready'
                  AND a.invalidated_at IS NULL
                  AND a.is_excluded = 0
                  AND a.id = ?
                ORDER BY a.relative_path COLLATE NOCASE
                LIMIT 1
                """
            )
            try query.bind(.text(activeAssetID), at: 1)
            guard try query.step(),
                  let jobID = query.text(at: 0),
                  let asset = segmentationAsset(from: query, offset: 3) else {
                return .idle
            }
            let candidateDuration = query.integer(at: 18)
            let attempt = Int(query.integer(at: 1)) + 1
            let createdAt = Date(timeIntervalSince1970: query.real(at: 2))
            let update = try connection.prepare(
                """
                UPDATE job
                SET status = 'running', attempt_count = ?,
                    checkpoint_json = json_set(
                        coalesce(checkpoint_json, '{}'), '$.stage', 'analyzing'
                    ),
                    error_message = NULL, updated_at = ?
                WHERE id = ? AND status = 'pending'
                RETURNING id
                """
            )
            try update.bind(.integer(Int64(attempt)), at: 1)
            try update.bind(.real(now.timeIntervalSince1970), at: 2)
            try update.bind(.text(jobID), at: 3)
            guard try update.step() else { throw SegmentationDatabaseError.staleClaim }
            return .target(
                AssetSegmentationTarget(
                    job: AssetSegmentationJobRecord(
                        id: jobID,
                        assetID: asset.id,
                        status: .running,
                        attemptCount: attempt,
                        stage: "analyzing",
                        errorMessage: nil,
                        createdAt: createdAt,
                        updatedAt: now
                    ),
                    asset: asset,
                    candidateDurationMS: candidateDuration > 0 ? candidateDuration : nil
                )
            )
        }
    }

    public func updateSegmentationJob(
        claim: JobClaimToken,
        stage: String,
        now: Date = Date()
    ) throws {
        let statement = try connection.prepare(
            """
            UPDATE job
            SET checkpoint_json = json_set(
                    coalesce(checkpoint_json, '{}'), '$.stage', ?
                ),
                updated_at = ?
            WHERE id = ? AND kind = 'segment_asset'
              AND status = 'running' AND attempt_count = ?
            RETURNING id
            """
        )
        try statement.bind(.text(stage), at: 1)
        try statement.bind(.real(now.timeIntervalSince1970), at: 2)
        try statement.bind(.text(claim.jobID), at: 3)
        try statement.bind(.integer(Int64(claim.attemptCount)), at: 4)
        guard try statement.step() else { throw SegmentationDatabaseError.staleClaim }
    }

    public func returnSegmentationJobToQueue(
        claim: JobClaimToken,
        stage: String = "paused",
        now: Date = Date()
    ) throws {
        let statement = try connection.prepare(
            """
            UPDATE job
            SET status = 'pending',
                checkpoint_json = json_set(
                    coalesce(checkpoint_json, '{}'), '$.stage', ?
                ),
                error_message = NULL, updated_at = ?
            WHERE id = ? AND kind = 'segment_asset'
              AND status = 'running' AND attempt_count = ?
            RETURNING id
            """
        )
        try statement.bind(.text(stage), at: 1)
        try statement.bind(.real(now.timeIntervalSince1970), at: 2)
        try statement.bind(.text(claim.jobID), at: 3)
        try statement.bind(.integer(Int64(claim.attemptCount)), at: 4)
        guard try statement.step() else { throw SegmentationDatabaseError.staleClaim }
    }

    public func failSegmentationJob(
        claim: JobClaimToken,
        message: String,
        now: Date = Date()
    ) throws {
        let statement = try connection.prepare(
            """
            UPDATE job
            SET status = 'failed',
                checkpoint_json = json_set(
                    coalesce(checkpoint_json, '{}'), '$.stage', ?
                ),
                error_message = ?, updated_at = ?
            WHERE id = ? AND kind = 'segment_asset'
              AND status = 'running' AND attempt_count = ?
            RETURNING id
            """
        )
        try statement.bind(.text("failed"), at: 1)
        try statement.bind(.text(message), at: 2)
        try statement.bind(.real(now.timeIntervalSince1970), at: 3)
        try statement.bind(.text(claim.jobID), at: 4)
        try statement.bind(.integer(Int64(claim.attemptCount)), at: 5)
        guard try statement.step() else { throw SegmentationDatabaseError.staleClaim }
    }

    /// Stores a new semantic generation beside the currently active segments.
    /// Existing searchable data remains active until every new segment has an embedding.
    /// `candidateDurationMS` 携带同指纹时长漂移的确认值：暂存进 run 参数，
    /// 激活事务内才落定为权威时长；提交本身只清除挂起标记，不提前覆盖。
    public func commitSegmentation(
        claim: JobClaimToken,
        assetID: String,
        sourceFingerprint: String,
        algorithmVersion: String,
        parametersJSON: String,
        segments: [SemanticSegmentDraft],
        observations: [TimelineBoundaryObservationDraft] = [],
        candidateDurationMS: Int64? = nil,
        now: Date = Date()
    ) throws {
        try validateSegmentation(segments, assetID: assetID)
        try connection.inTransaction {
            let assetQuery = try connection.prepare(
                """
                SELECT a.duration_ms
                FROM job j
                JOIN media_asset a ON a.id = j.asset_id
                WHERE j.id = ? AND j.kind = 'segment_asset'
                  AND j.status = 'running' AND j.attempt_count = ?
                  AND a.id = ? AND a.fingerprint = ?
                  AND a.status = 'ready' AND a.invalidated_at IS NULL
                  AND a.is_excluded = 0
                """
            )
            try assetQuery.bind(.text(claim.jobID), at: 1)
            try assetQuery.bind(.integer(Int64(claim.attemptCount)), at: 2)
            try assetQuery.bind(.text(assetID), at: 3)
            try assetQuery.bind(.text(sourceFingerprint), at: 4)
            guard try assetQuery.step() else { throw SegmentationDatabaseError.missingAsset }
            let storedDurationMS = assetQuery.integer(at: 0)
            let authoritativeDurationMS = candidateDurationMS ?? storedDurationMS
            guard segments.first?.startMS == 0,
                  segments.last?.endMS == authoritativeDurationMS else {
                throw SegmentationDatabaseError.invalidCoverage
            }

            // An algorithm upgrade may arrive while the preceding semantic
            // generation is still being indexed. Retire every older staged run
            // and invalidate its claims before creating the new generation;
            // otherwise it could become complete later and roll search back.
            let retireRuns = try connection.prepare(
                """
                UPDATE derivation_run
                SET status = 'cancelled', completed_at = ?,
                    error_message = 'superseded by a newer segmentation generation'
                WHERE asset_id = ? AND kind = 'segmentation' AND status = 'running'
                """
            )
            try retireRuns.bind(.real(now.timeIntervalSince1970), at: 1)
            try retireRuns.bind(.text(assetID), at: 2)
            _ = try retireRuns.step()

            let retireJobs = try connection.prepare(
                """
                UPDATE job
                SET status = 'cancelled', checkpoint_json = json_set(
                        coalesce(checkpoint_json, '{}'), '$.stage', 'superseded'
                    ),
                    error_message = NULL, updated_at = ?
                WHERE kind IN ('index_segment', 'describe_segment')
                  AND status IN ('pending', 'running')
                  AND segment_id IN (
                    SELECT s.id
                    FROM segment s
                    JOIN derivation_run r ON r.id = s.segmentation_run_id
                    WHERE s.asset_id = ? AND r.kind = 'segmentation'
                      AND r.status = 'cancelled'
                  )
                """
            )
            try retireJobs.bind(.real(now.timeIntervalSince1970), at: 1)
            try retireJobs.bind(.text(assetID), at: 2)
            _ = try retireJobs.step()

            // A staged generation was never user-visible and is not a valid
            // rollback point. Deleting it also cascades its cancelled jobs and
            // evidence, leaving the genuinely active generation as the one
            // previous generation retained after the next activation.
            let deleteRetiredSegments = try connection.prepare(
                """
                DELETE FROM segment
                WHERE asset_id = ? AND is_active = 0
                  AND segmentation_run_id IN (
                    SELECT id FROM derivation_run
                    WHERE asset_id = ? AND kind = 'segmentation'
                      AND status = 'cancelled'
                  )
                """
            )
            try deleteRetiredSegments.bind(.text(assetID), at: 1)
            try deleteRetiredSegments.bind(.text(assetID), at: 2)
            _ = try deleteRetiredSegments.step()

            let deleteRetiredRuns = try connection.prepare(
                """
                DELETE FROM derivation_run
                WHERE asset_id = ? AND kind = 'segmentation'
                  AND status = 'cancelled'
                  AND NOT EXISTS (
                    SELECT 1 FROM segment s
                    WHERE s.segmentation_run_id = derivation_run.id
                  )
                """
            )
            try deleteRetiredRuns.bind(.text(assetID), at: 1)
            _ = try deleteRetiredRuns.step()

            let runID = UUID().uuidString
            let runParametersJSON = Self.runParameters(
                parametersJSON,
                candidateDurationMS: candidateDurationMS,
                authoritativeDurationMS: storedDurationMS
            )
            let run = try connection.prepare(
                """
                INSERT INTO derivation_run (
                    id, asset_id, kind, model_id, model_sha, runtime_version,
                    parameters_json, source_fingerprint, status, started_at,
                    completed_at, error_message
                ) VALUES (?, ?, 'segmentation', NULL, NULL, ?, ?, ?, 'running', ?, NULL, NULL)
                """
            )
            try run.bind(.text(runID), at: 1)
            try run.bind(.text(assetID), at: 2)
            try run.bind(.text(algorithmVersion), at: 3)
            try run.bind(.text(runParametersJSON), at: 4)
            try run.bind(.text(sourceFingerprint), at: 5)
            try run.bind(.real(now.timeIntervalSince1970), at: 6)
            _ = try run.step()

            // 候选已随本次提交进入 run 参数；挂起标记必须同时清除，否则
            // reconcile 会无限重置该任务。
            let clearCandidate = try connection.prepare(
                "UPDATE media_asset SET candidate_duration_ms = NULL WHERE id = ?"
            )
            try clearCandidate.bind(.text(assetID), at: 1)
            _ = try clearCandidate.step()

            for (index, observation) in observations.enumerated()
            where observation.timeMS >= 0 && observation.timeMS <= authoritativeDurationMS {
                let insert = try connection.prepare(
                    """
                    INSERT INTO timeline_boundary_observation (
                        id, derivation_run_id, asset_id, time_ms, kind, score, details_json
                    ) VALUES (?, ?, ?, ?, ?, ?, ?)
                    """
                )
                try insert.bind(.text("\(runID):boundary:\(index)"), at: 1)
                try insert.bind(.text(runID), at: 2)
                try insert.bind(.text(assetID), at: 3)
                try insert.bind(.integer(observation.timeMS), at: 4)
                try insert.bind(.text(observation.kind.rawValue), at: 5)
                try insert.bind(.real(min(1, max(0, observation.score))), at: 6)
                try insert.bind(.text(observation.detailsJSON), at: 7)
                _ = try insert.step()
            }

            let generationQuery = try connection.prepare(
                "SELECT coalesce(max(segmentation_version), 1) + 1 FROM segment WHERE asset_id = ?"
            )
            try generationQuery.bind(.text(assetID), at: 1)
            guard try generationQuery.step() else { throw SegmentationDatabaseError.missingAsset }
            let generation = max(2, Int(generationQuery.integer(at: 0)))

            for (ordinal, value) in segments.enumerated() {
                let insert = try connection.prepare(
                    """
                    INSERT INTO segment (
                        id, asset_id, ordinal, start_ms, end_ms,
                        segmentation_version, segmentation_run_id, is_active
                    ) VALUES (?, ?, ?, ?, ?, ?, ?, 0)
                    """
                )
                // 段 ID 必须含 runID：同一算法版本的时长漂移修正会与仍服役的
                // 旧 ACTIVE 代际并行存在，仅凭算法版本+边界无法区分两代，
                // 相同边界（典型如尾部前的一段）会主键冲突。
                let segmentID = "\(assetID):\(runID):\(value.startMS):\(value.endMS)"
                try insert.bind(.text(segmentID), at: 1)
                try insert.bind(.text(assetID), at: 2)
                try insert.bind(.integer(Int64(ordinal)), at: 3)
                try insert.bind(.integer(value.startMS), at: 4)
                try insert.bind(.integer(value.endMS), at: 5)
                try insert.bind(.integer(Int64(generation)), at: 6)
                try insert.bind(.text(runID), at: 7)
                _ = try insert.step()
            }

            // Do not waste model work on the legacy fallback after a content
            // generation exists. Existing committed evidence remains untouched.
            let removePendingLegacy = try connection.prepare(
                """
                DELETE FROM job
                WHERE kind IN ('index_segment', 'describe_segment')
                  AND status = 'pending'
                  AND segment_id IN (
                    SELECT id FROM segment
                    WHERE asset_id = ? AND segmentation_run_id IS NULL
                  )
                """
            )
            try removePendingLegacy.bind(.text(assetID), at: 1)
            _ = try removePendingLegacy.step()

            let indexedActive = try connection.prepare(
                """
                SELECT count(*)
                FROM segment_embedding e
                JOIN segment s ON s.id = e.segment_id
                WHERE s.asset_id = ? AND s.is_active = 1
                """
            )
            try indexedActive.bind(.text(assetID), at: 1)
            guard try indexedActive.step() else { throw SegmentationDatabaseError.missingAsset }
            if indexedActive.integer(at: 0) == 0 {
                try activateSegmentationRun(runID: runID, assetID: assetID, now: now)
            }

            let finish = try connection.prepare(
                """
                UPDATE job
                SET status = 'succeeded', checkpoint_json = ?, error_message = NULL, updated_at = ?
                WHERE id = ? AND kind = 'segment_asset'
                  AND status = 'running' AND attempt_count = ?
                RETURNING id
                """
            )
            try finish.bind(
                .text(segmentationCheckpoint(
                    stage: "complete",
                    algorithmVersion: algorithmVersion,
                    sourceFingerprint: sourceFingerprint
                )),
                at: 1
            )
            try finish.bind(.real(now.timeIntervalSince1970), at: 2)
            try finish.bind(.text(claim.jobID), at: 3)
            try finish.bind(.integer(Int64(claim.attemptCount)), at: 4)
            guard try finish.step() else { throw SegmentationDatabaseError.staleClaim }
        }
    }

    /// 探测漂移被解码时长判为误报时的完成入口：不旁路新代际，
    /// 清掉挂起候选并正常结任务；现有活动代际与权威时长保持不变。
    public func dismissSegmentationDurationCandidate(
        claim: JobClaimToken,
        now: Date = Date()
    ) throws {
        try connection.inTransaction {
            let finish = try connection.prepare(
                """
                UPDATE job
                SET status = 'succeeded', checkpoint_json = ?,
                    error_message = NULL, updated_at = ?
                WHERE id = ? AND kind = 'segment_asset'
                  AND status = 'running' AND attempt_count = ?
                RETURNING asset_id
                """
            )
            try finish.bind(
                .text(segmentationCheckpoint(
                    stage: "duration_drift_dismissed",
                    algorithmVersion: nil,
                    sourceFingerprint: nil
                )),
                at: 1
            )
            try finish.bind(.real(now.timeIntervalSince1970), at: 2)
            try finish.bind(.text(claim.jobID), at: 3)
            try finish.bind(.integer(Int64(claim.attemptCount)), at: 4)
            guard try finish.step(),
                  let assetID = finish.text(at: 0) else {
                throw SegmentationDatabaseError.staleClaim
            }
            let clear = try connection.prepare(
                "UPDATE media_asset SET candidate_duration_ms = NULL WHERE id = ?"
            )
            try clear.bind(.text(assetID), at: 1)
            _ = try clear.step()
        }
    }

    /// Activates a staged generation only after its complete embedding set exists.
    /// Returns true when this call performed the atomic switch.
    public func activateReadySegmentation(assetID: String, now: Date = Date()) throws -> Bool {
        try connection.inTransaction {
            let query = try connection.prepare(
                """
                SELECT r.id, count(s.id), count(e.segment_id)
                FROM derivation_run r
                JOIN segment s ON s.segmentation_run_id = r.id
                LEFT JOIN segment_embedding e ON e.segment_id = s.id
                JOIN media_asset a ON a.id = r.asset_id
                WHERE r.asset_id = ?
                  AND r.kind = 'segmentation'
                  AND r.status = 'running'
                  AND r.source_fingerprint = a.fingerprint
                GROUP BY r.id, r.started_at
                ORDER BY r.started_at DESC
                LIMIT 1
                """
            )
            try query.bind(.text(assetID), at: 1)
            guard try query.step(), let runID = query.text(at: 0) else { return false }
            let total = query.integer(at: 1)
            let embedded = query.integer(at: 2)
            guard total > 0, embedded == total else { return false }
            try activateSegmentationRun(runID: runID, assetID: assetID, now: now)
            return true
        }
    }

    @discardableResult
    public func activateAllReadySegmentations(now: Date = Date()) throws -> Bool {
        let query = try connection.prepare(
            """
            SELECT DISTINCT asset_id
            FROM derivation_run
            WHERE kind = 'segmentation' AND status = 'running'
            ORDER BY asset_id
            """
        )
        var assetIDs: [String] = []
        while try query.step(), let assetID = query.text(at: 0) {
            assetIDs.append(assetID)
        }
        var activatedAny = false
        for assetID in assetIDs {
            if try activateReadySegmentation(assetID: assetID, now: now) {
                activatedAny = true
            }
        }
        return activatedAny
    }

    public func segmentationProgress() throws -> IndexingProgress {
        let statement = try connection.prepare(
            """
            SELECT count(*),
                   sum(CASE WHEN j.status = 'pending' THEN 1 ELSE 0 END),
                   sum(CASE WHEN j.status = 'running' THEN 1 ELSE 0 END),
                   sum(CASE WHEN j.status = 'succeeded' THEN 1 ELSE 0 END),
                   sum(CASE WHEN j.status IN ('failed', 'cancelled') THEN 1 ELSE 0 END)
            FROM job j
            JOIN media_asset a ON a.id = j.asset_id
            WHERE j.kind = 'segment_asset'
              AND a.status = 'ready' AND a.invalidated_at IS NULL AND a.is_excluded = 0
            """
        )
        guard try statement.step() else {
            return IndexingProgress(total: 0, pending: 0, running: 0, succeeded: 0, failed: 0)
        }
        return IndexingProgress(
            total: Int(statement.integer(at: 0)),
            pending: Int(statement.integer(at: 1)),
            running: Int(statement.integer(at: 2)),
            succeeded: Int(statement.integer(at: 3)),
            failed: Int(statement.integer(at: 4))
        )
    }

    /// Returns the auditable boundary evidence for the currently active
    /// semantic generation. A staged generation stays invisible here until the
    /// same atomic activation used by search.
    public func activeTimelineBoundaryObservations(
        assetID: String
    ) throws -> [TimelineBoundaryObservationRecord] {
        let statement = try connection.prepare(
            """
            SELECT DISTINCT o.id, o.derivation_run_id, o.asset_id,
                   o.time_ms, o.kind, o.score, o.details_json
            FROM timeline_boundary_observation o
            JOIN segment s ON s.segmentation_run_id = o.derivation_run_id
            WHERE o.asset_id = ? AND s.is_active = 1
            ORDER BY o.time_ms, o.id
            """
        )
        try statement.bind(.text(assetID), at: 1)
        var records: [TimelineBoundaryObservationRecord] = []
        while try statement.step(),
              let id = statement.text(at: 0),
              let runID = statement.text(at: 1),
              let storedAssetID = statement.text(at: 2),
              let kindText = statement.text(at: 4),
              let kind = TimelineBoundaryKind(rawValue: kindText),
              let detailsJSON = statement.text(at: 6) {
            records.append(
                TimelineBoundaryObservationRecord(
                    id: id,
                    derivationRunID: runID,
                    assetID: storedAssetID,
                    timeMS: statement.integer(at: 3),
                    kind: kind,
                    score: statement.real(at: 5),
                    detailsJSON: detailsJSON
                )
            )
        }
        return records
    }

    private func activateSegmentationRun(runID: String, assetID: String, now: Date) throws {
        let previousActive = try connection.prepare(
            "SELECT max(segmentation_version) FROM segment WHERE asset_id = ? AND is_active = 1"
        )
        try previousActive.bind(.text(assetID), at: 1)
        let previousActiveVersion: Int64?
        if try previousActive.step() {
            let version = previousActive.integer(at: 0)
            previousActiveVersion = version > 0 ? version : nil
        } else {
            previousActiveVersion = nil
        }

        let deactivate = try connection.prepare(
            "UPDATE segment SET is_active = 0 WHERE asset_id = ?"
        )
        try deactivate.bind(.text(assetID), at: 1)
        _ = try deactivate.step()

        let activate = try connection.prepare(
            "UPDATE segment SET is_active = 1 WHERE segmentation_run_id = ? AND asset_id = ?"
        )
        try activate.bind(.text(runID), at: 1)
        try activate.bind(.text(assetID), at: 2)
        _ = try activate.step()

        let complete = try connection.prepare(
            """
            UPDATE derivation_run
            SET status = 'succeeded', completed_at = ?, error_message = NULL
            WHERE id = ? AND asset_id = ? AND kind = 'segmentation' AND status = 'running'
            """
        )
        try complete.bind(.real(now.timeIntervalSince1970), at: 1)
        try complete.bind(.text(runID), at: 2)
        try complete.bind(.text(assetID), at: 3)
        _ = try complete.step()

        // 漂移修正代际激活：候选时长与活动代际在同一事务内落定，旧代际
        // 服役期间权威时长始终与其覆盖一致。
        let candidateQuery = try connection.prepare(
            """
            SELECT json_extract(parameters_json, '$.candidate_duration_ms')
            FROM derivation_run
            WHERE id = ? AND asset_id = ? AND kind = 'segmentation'
              AND status = 'succeeded' AND json_valid(parameters_json)
            """
        )
        try candidateQuery.bind(.text(runID), at: 1)
        try candidateQuery.bind(.text(assetID), at: 2)
        if try candidateQuery.step() {
            let candidateMS = candidateQuery.integer(at: 0)
            if candidateMS > 0 {
                let apply = try connection.prepare(
                    """
                    UPDATE media_asset
                    SET duration_ms = ?, candidate_duration_ms = NULL
                    WHERE id = ?
                    """
                )
                try apply.bind(.integer(candidateMS), at: 1)
                try apply.bind(.text(assetID), at: 2)
                _ = try apply.step()
            }
        }

        // Keep exactly the generation that was active immediately before this
        // switch. A newer cancelled/failed staged generation must never evict
        // the real rollback generation merely because its version is larger.
        if let previousActiveVersion {
            let prune = try connection.prepare(
                """
                DELETE FROM segment
                WHERE asset_id = ? AND is_active = 0 AND segmentation_version <> ?
                """
            )
            try prune.bind(.text(assetID), at: 1)
            try prune.bind(.integer(previousActiveVersion), at: 2)
            _ = try prune.step()
        } else {
            let prune = try connection.prepare(
                "DELETE FROM segment WHERE asset_id = ? AND is_active = 0"
            )
            try prune.bind(.text(assetID), at: 1)
            _ = try prune.step()
        }

        let pruneSegmentationRuns = try connection.prepare(
            """
            DELETE FROM derivation_run
            WHERE asset_id = ? AND kind = 'segmentation' AND status <> 'running'
              AND NOT EXISTS (
                SELECT 1 FROM segment s
                WHERE s.segmentation_run_id = derivation_run.id
              )
            """
        )
        try pruneSegmentationRuns.bind(.text(assetID), at: 1)
        _ = try pruneSegmentationRuns.step()

        let pruneEvidenceRuns = try connection.prepare(
            """
            DELETE FROM derivation_run
            WHERE asset_id = ? AND kind <> 'segmentation' AND status <> 'running'
              AND NOT EXISTS (
                SELECT 1 FROM transcript_segment t
                WHERE t.derivation_run_id = derivation_run.id
              )
              AND NOT EXISTS (
                SELECT 1 FROM ocr_observation o
                WHERE o.derivation_run_id = derivation_run.id
              )
              AND NOT EXISTS (
                SELECT 1 FROM segment_embedding e
                WHERE e.derivation_run_id = derivation_run.id
              )
              AND NOT EXISTS (
                SELECT 1 FROM segment_description d
                WHERE d.derivation_run_id = derivation_run.id
              )
            """
        )
        try pruneEvidenceRuns.bind(.text(assetID), at: 1)
        _ = try pruneEvidenceRuns.step()
    }

    private func validateSegmentation(
        _ segments: [SemanticSegmentDraft],
        assetID: String
    ) throws {
        guard !segments.isEmpty, segments[0].startMS == 0 else {
            throw SegmentationDatabaseError.invalidCoverage
        }
        var cursor: Int64 = 0
        for value in segments {
            guard value.startMS == cursor, value.endMS > value.startMS else {
                throw SegmentationDatabaseError.invalidCoverage
            }
            cursor = value.endMS
        }
        guard cursor > 0, !assetID.isEmpty else {
            throw SegmentationDatabaseError.invalidCoverage
        }
    }

    private static func runParameters(
        _ parametersJSON: String,
        candidateDurationMS: Int64?,
        authoritativeDurationMS: Int64
    ) -> String {
        guard let candidateDurationMS, candidateDurationMS != authoritativeDurationMS else {
            return parametersJSON
        }
        guard var object = try? JSONSerialization.jsonObject(
            with: Data(parametersJSON.utf8)
        ) as? [String: Any] else {
            return "{\"candidate_duration_ms\":\(candidateDurationMS)}"
        }
        object["candidate_duration_ms"] = candidateDurationMS
        guard let data = try? JSONSerialization.data(
            withJSONObject: object,
            options: [.sortedKeys]
        ) else { return parametersJSON }
        return String(decoding: data, as: UTF8.self)
    }

    private func segmentationCheckpoint(
        stage: String,
        algorithmVersion: String?,
        sourceFingerprint: String?
    ) -> String {
        var value = ["stage": stage]
        if let algorithmVersion { value["algorithm_version"] = algorithmVersion }
        if let sourceFingerprint { value["source_fingerprint"] = sourceFingerprint }
        let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
        return data.map { String(decoding: $0, as: UTF8.self) } ?? "{}"
    }

    private func segmentationAsset(
        from statement: SQLiteStatement,
        offset: Int32
    ) -> MediaAssetRecord? {
        guard let id = statement.text(at: offset),
              let rootID = statement.text(at: offset + 1),
              let relativePath = statement.text(at: offset + 2),
              let standardizedPath = statement.text(at: offset + 3),
              let fingerprint = statement.text(at: offset + 10),
              let statusText = statement.text(at: offset + 11),
              let status = MediaAssetStatus(rawValue: statusText) else {
            return nil
        }
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
            lastSeenAt: Date(timeIntervalSince1970: statement.real(at: offset + 14)),
            mediaKind: MediaKind(rawValue: statement.text(at: offset + 16) ?? "") ?? .video,
            pixelWidth: Int(statement.integer(at: offset + 17)),
            pixelHeight: Int(statement.integer(at: offset + 18))
        )
    }
}
