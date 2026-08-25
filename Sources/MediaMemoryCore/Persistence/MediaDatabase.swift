import Foundation

public enum MediaDatabaseOpenError: Error, LocalizedError, Equatable, Sendable {
    case unsupportedSchemaVersion(Int64)

    public var errorDescription: String? {
        switch self {
        case let .unsupportedSchemaVersion(version):
            "数据库版本 \(version) 高于当前应用支持的版本 7，请使用更新版本的 Media Memory。"
        }
    }
}

public actor MediaDatabase {
    let connection: SQLiteConnection

    public init(url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        connection = try SQLiteConnection(url: url)
        try Self.migrate(connection)
    }

    /// Opens an OS-enforced read-only WAL connection. App snapshots and search
    /// use this actor so they neither share the writer actor queue nor gain an
    /// accidental mutation path at runtime.
    public init(readOnlyURL url: URL) throws {
        connection = try SQLiteConnection(url: url, readOnly: true)
    }

    public func addLibraryRoot(
        path: String,
        bookmark: Data,
        kind: LibraryRootKind = .directory
    ) throws -> LibraryRootRecord {
        let normalizedPath = URL(fileURLWithPath: path).standardizedFileURL.path
        let now = Date()
        let existing = try root(path: normalizedPath)
        let id = existing?.id ?? UUID().uuidString
        let createdAt = existing?.createdAt ?? now

        let statement = try connection.prepare(
            """
            INSERT INTO library_root (
                id, path, kind, bookmark, is_enabled, created_at, last_scan_at
            ) VALUES (?, ?, ?, ?, 1, ?, ?)
            ON CONFLICT(path) DO UPDATE SET
                bookmark = excluded.bookmark,
                kind = excluded.kind,
                is_enabled = 1
            """
        )
        try statement.bind(.text(id), at: 1)
        try statement.bind(.text(normalizedPath), at: 2)
        try statement.bind(.text(kind.rawValue), at: 3)
        try statement.bind(.blob(bookmark), at: 4)
        try statement.bind(.real(createdAt.timeIntervalSince1970), at: 5)
        if let lastScanAt = existing?.lastScanAt {
            try statement.bind(.real(lastScanAt.timeIntervalSince1970), at: 6)
        } else {
            try statement.bind(.null, at: 6)
        }
        _ = try statement.step()

        return LibraryRootRecord(
            id: id,
            path: normalizedPath,
            kind: kind,
            bookmark: bookmark,
            isEnabled: true,
            createdAt: createdAt,
            lastScanAt: existing?.lastScanAt
        )
    }

    public func libraryRoots() throws -> [LibraryRootRecord] {
        let statement = try connection.prepare(
            """
            SELECT id, path, kind, bookmark, is_enabled, created_at, last_scan_at
            FROM library_root
            ORDER BY created_at, path
            """
        )
        var roots: [LibraryRootRecord] = []
        while try statement.step() {
            guard let id = statement.text(at: 0),
                  let path = statement.text(at: 1),
                  let bookmark = statement.blob(at: 3) else {
                continue
            }
            let lastScan = statement.real(at: 6)
            roots.append(
                LibraryRootRecord(
                    id: id,
                    path: path,
                    kind: Self.rootKind(statement.text(at: 2)),
                    bookmark: bookmark,
                    isEnabled: statement.integer(at: 4) != 0,
                    createdAt: Date(timeIntervalSince1970: statement.real(at: 5)),
                    lastScanAt: lastScan > 0 ? Date(timeIntervalSince1970: lastScan) : nil
                )
            )
        }
        return roots
    }

    private static func rootKind(_ raw: String?) -> LibraryRootKind {
        raw.flatMap(LibraryRootKind.init(rawValue:)) ?? .directory
    }

    public func setLibraryRootEnabled(id: String, enabled: Bool) throws {
        let statement = try connection.prepare(
            "UPDATE library_root SET is_enabled = ? WHERE id = ?"
        )
        try statement.bind(.integer(enabled ? 1 : 0), at: 1)
        try statement.bind(.text(id), at: 2)
        _ = try statement.step()
    }

    /// Refreshes an existing root's security-scoped bookmark without upserting
    /// a missing root. Bookmark renewal can finish after a user removes a root;
    /// a conditional update prevents that stale continuation from recreating it.
    public func updateLibraryRootBookmark(id: String, bookmark: Data) throws {
        let statement = try connection.prepare(
            "UPDATE library_root SET bookmark = ? WHERE id = ?"
        )
        try statement.bind(.blob(bookmark), at: 1)
        try statement.bind(.text(id), at: 2)
        _ = try statement.step()
    }

    public func applyScan(rootID: String, result: MediaScanResult, scannedAt: Date = Date()) throws {
        try connection.inTransaction {
            if result.isAuthoritativeComplete {
                let missing = try connection.prepare(
                    """
                    UPDATE media_asset
                    SET status = 'missing', invalidated_at = ?
                    WHERE root_id = ? AND invalidated_at IS NULL
                    """
                )
                try missing.bind(.real(scannedAt.timeIntervalSince1970), at: 1)
                try missing.bind(.text(rootID), at: 2)
                _ = try missing.step()
            }

            for asset in result.assets {
                try upsert(asset: asset, rootID: rootID, seenAt: scannedAt)
            }

            if result.isAuthoritativeComplete {
                let root = try connection.prepare(
                    "UPDATE library_root SET last_scan_at = ? WHERE id = ?"
                )
                try root.bind(.real(scannedAt.timeIntervalSince1970), at: 1)
                try root.bind(.text(rootID), at: 2)
                _ = try root.step()
            }
        }
    }

    public func mediaAssets(rootID: String? = nil) throws -> [MediaAssetRecord] {
        let sql: String
        if rootID == nil {
            sql = """
                SELECT id, root_id, relative_path, standardized_path, file_size,
                       modification_time, duration_ms, video_track_count,
                       audio_track_count, is_playable, fingerprint, status,
                       error_message, first_seen_at, last_seen_at
                FROM media_asset
                WHERE invalidated_at IS NULL AND is_excluded = 0
                ORDER BY relative_path COLLATE NOCASE
                """
        } else {
            sql = """
                SELECT id, root_id, relative_path, standardized_path, file_size,
                       modification_time, duration_ms, video_track_count,
                       audio_track_count, is_playable, fingerprint, status,
                       error_message, first_seen_at, last_seen_at
                FROM media_asset
                WHERE root_id = ? AND invalidated_at IS NULL AND is_excluded = 0
                ORDER BY relative_path COLLATE NOCASE
                """
        }

        let statement = try connection.prepare(sql)
        if let rootID {
            try statement.bind(.text(rootID), at: 1)
        }
        var assets: [MediaAssetRecord] = []
        while try statement.step() {
            guard let id = statement.text(at: 0),
                  let storedRootID = statement.text(at: 1),
                  let relativePath = statement.text(at: 2),
                  let standardizedPath = statement.text(at: 3),
                  let fingerprint = statement.text(at: 10),
                  let statusText = statement.text(at: 11),
                  let status = MediaAssetStatus(rawValue: statusText) else {
                continue
            }
            assets.append(
                MediaAssetRecord(
                    id: id,
                    rootID: storedRootID,
                    relativePath: relativePath,
                    standardizedPath: standardizedPath,
                    fileSize: statement.integer(at: 4),
                    modificationDate: Date(timeIntervalSince1970: statement.real(at: 5)),
                    durationMS: statement.integer(at: 6),
                    videoTrackCount: Int(statement.integer(at: 7)),
                    audioTrackCount: Int(statement.integer(at: 8)),
                    isPlayable: statement.integer(at: 9) != 0,
                    fingerprint: fingerprint,
                    status: status,
                    errorMessage: statement.text(at: 12),
                    firstSeenAt: Date(timeIntervalSince1970: statement.real(at: 13)),
                    lastSeenAt: Date(timeIntervalSince1970: statement.real(at: 14))
                )
            )
        }
        return assets
    }

    public func librarySnapshot() throws -> MediaLibrarySnapshot {
        try connection.inReadTransaction {
            MediaLibrarySnapshot(
                roots: try libraryRoots(),
                assets: try mediaAssets(),
                processingSummaries: try assetProcessingSummaries()
            )
        }
    }

    public func segments(assetID: String) throws -> [SegmentRecord] {
        let statement = try connection.prepare(
            """
            SELECT id, asset_id, ordinal, start_ms, end_ms, segmentation_version
            FROM segment
            WHERE asset_id = ? AND is_active = 1
            ORDER BY ordinal
            """
        )
        try statement.bind(.text(assetID), at: 1)
        var segments: [SegmentRecord] = []
        while try statement.step() {
            guard let id = statement.text(at: 0),
                  let storedAssetID = statement.text(at: 1) else {
                continue
            }
            segments.append(
                SegmentRecord(
                    id: id,
                    assetID: storedAssetID,
                    ordinal: Int(statement.integer(at: 2)),
                    startMS: statement.integer(at: 3),
                    endMS: statement.integer(at: 4),
                    segmentationVersion: Int(statement.integer(at: 5))
                )
            )
        }
        return segments
    }

    /// 按资产汇总全部建库产物：片段及其建库状态、ASR 句子、OCR 观察值。
    public func assetLibraryDetail(assetID: String) throws -> AssetLibraryDetail {
        let segmentStatement = try connection.prepare(
            """
            SELECT s.id, s.asset_id, s.ordinal, s.start_ms, s.end_ms,
                   s.segmentation_version,
                   EXISTS (SELECT 1 FROM segment_embedding e WHERE e.segment_id = s.id),
                   (SELECT count(*) FROM segment_frame f WHERE f.segment_id = s.id),
                   j.status
            FROM segment s
            LEFT JOIN job j
                ON j.segment_id = s.id AND j.kind = 'describe_segment'
            WHERE s.asset_id = ? AND s.is_active = 1
            ORDER BY s.ordinal
            """
        )
        try segmentStatement.bind(.text(assetID), at: 1)
        var segments: [AssetSegmentInfo] = []
        while try segmentStatement.step() {
            guard let id = segmentStatement.text(at: 0),
                  let storedAssetID = segmentStatement.text(at: 1) else {
                continue
            }
            segments.append(
                AssetSegmentInfo(
                    segment: SegmentRecord(
                        id: id,
                        assetID: storedAssetID,
                        ordinal: Int(segmentStatement.integer(at: 2)),
                        startMS: segmentStatement.integer(at: 3),
                        endMS: segmentStatement.integer(at: 4),
                        segmentationVersion: Int(segmentStatement.integer(at: 5))
                    ),
                    isIndexed: segmentStatement.integer(at: 6) != 0,
                    frameCount: Int(segmentStatement.integer(at: 7)),
                    describeStatus: segmentStatement.text(at: 8).flatMap(JobStatus.init(rawValue:))
                )
            )
        }

        let transcriptStatement = try connection.prepare(
            """
            SELECT t.id, t.segment_id, t.text, t.language, t.start_ms, t.end_ms, t.timing_source
            FROM transcript_segment t
            JOIN segment s ON s.id = t.segment_id
            WHERE s.asset_id = ? AND s.is_active = 1
            ORDER BY t.start_ms, t.rowid
            """
        )
        try transcriptStatement.bind(.text(assetID), at: 1)
        var transcripts: [TranscriptEvidenceRecord] = []
        while try transcriptStatement.step() {
            guard let id = transcriptStatement.text(at: 0),
                  let segmentID = transcriptStatement.text(at: 1),
                  let text = transcriptStatement.text(at: 2),
                  let timingSource = transcriptStatement.text(at: 6) else {
                continue
            }
            transcripts.append(
                TranscriptEvidenceRecord(
                    id: id,
                    segmentID: segmentID,
                    text: text,
                    language: transcriptStatement.text(at: 3),
                    startMS: transcriptStatement.integer(at: 4),
                    endMS: transcriptStatement.integer(at: 5),
                    timingSource: timingSource
                )
            )
        }

        let ocrStatement = try connection.prepare(
            """
            SELECT o.id, o.segment_id, o.text, o.confidence, o.start_ms, o.end_ms
            FROM ocr_observation o
            JOIN segment s ON s.id = o.segment_id
            WHERE s.asset_id = ? AND s.is_active = 1
            ORDER BY o.start_ms, o.rowid
            """
        )
        try ocrStatement.bind(.text(assetID), at: 1)
        var ocrRecords: [OCREvidenceRecord] = []
        while try ocrStatement.step() {
            guard let id = ocrStatement.text(at: 0),
                  let segmentID = ocrStatement.text(at: 1),
                  let text = ocrStatement.text(at: 2) else {
                continue
            }
            ocrRecords.append(
                OCREvidenceRecord(
                    id: id,
                    segmentID: segmentID,
                    text: text,
                    confidence: ocrStatement.real(at: 3),
                    startMS: ocrStatement.integer(at: 4),
                    endMS: ocrStatement.integer(at: 5)
                )
            )
        }

        let frameStatement = try connection.prepare(
            """
            SELECT f.id, f.segment_id, f.ordinal, f.time_ms, f.relative_path, f.perceptual_hash
            FROM segment_frame f
            JOIN segment s ON s.id = f.segment_id
            WHERE s.asset_id = ? AND s.is_active = 1
            ORDER BY s.ordinal, f.ordinal
            """
        )
        try frameStatement.bind(.text(assetID), at: 1)
        var frameRecords: [SegmentFrameRecord] = []
        while try frameStatement.step() {
            guard let id = frameStatement.text(at: 0),
                  let segmentID = frameStatement.text(at: 1),
                  let path = frameStatement.text(at: 4) else {
                continue
            }
            frameRecords.append(
                SegmentFrameRecord(
                    id: id,
                    segmentID: segmentID,
                    ordinal: Int(frameStatement.integer(at: 2)),
                    timeMS: frameStatement.integer(at: 3),
                    relativePath: path,
                    perceptualHash: UInt64(bitPattern: frameStatement.integer(at: 5))
                )
            )
        }

        return AssetLibraryDetail(
            segments: segments,
            transcripts: transcripts,
            ocr: ocrRecords,
            frames: frameRecords
        )
    }

    private func root(path: String) throws -> LibraryRootRecord? {
        let statement = try connection.prepare(
            """
            SELECT id, path, kind, bookmark, is_enabled, created_at, last_scan_at
            FROM library_root WHERE path = ?
            """
        )
        try statement.bind(.text(path), at: 1)
        guard try statement.step(),
              let id = statement.text(at: 0),
              let storedPath = statement.text(at: 1),
              let bookmark = statement.blob(at: 3) else {
            return nil
        }
        let lastScan = statement.real(at: 6)
        return LibraryRootRecord(
            id: id,
            path: storedPath,
            kind: Self.rootKind(statement.text(at: 2)),
            bookmark: bookmark,
            isEnabled: statement.integer(at: 4) != 0,
            createdAt: Date(timeIntervalSince1970: statement.real(at: 5)),
            lastScanAt: lastScan > 0 ? Date(timeIntervalSince1970: lastScan) : nil
        )
    }

    private func upsert(asset: ScannedMediaAsset, rootID: String, seenAt: Date) throws {
        let existing = try existingAsset(
            rootID: rootID,
            relativePath: asset.relativePath,
            fileIdentifier: asset.fileIdentifier
        )
        let assetID = existing?.id ?? UUID().uuidString
        let firstSeenAt = existing?.firstSeenAt ?? seenAt
        let needsNewSegments = existing == nil
            || existing?.fingerprint != asset.fingerprint
            || existing?.durationMS != asset.durationMS
            || (asset.status == .ready && existing?.segmentCount == 0)

        if needsNewSegments, existing != nil, !(try isExcluded(assetID: assetID)) {
            let delete = try connection.prepare("DELETE FROM segment WHERE asset_id = ?")
            try delete.bind(.text(assetID), at: 1)
            _ = try delete.step()
        }

        let statement = try connection.prepare(
            """
            INSERT INTO media_asset (
                id, root_id, relative_path, standardized_path, file_identifier,
                file_size, modification_time, duration_ms, video_track_count,
                audio_track_count, is_playable, fingerprint, status, error_message,
                first_seen_at, last_seen_at, invalidated_at
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, NULL)
            ON CONFLICT(id) DO UPDATE SET
                root_id = excluded.root_id,
                relative_path = excluded.relative_path,
                standardized_path = excluded.standardized_path,
                file_identifier = excluded.file_identifier,
                file_size = excluded.file_size,
                modification_time = excluded.modification_time,
                duration_ms = excluded.duration_ms,
                video_track_count = excluded.video_track_count,
                audio_track_count = excluded.audio_track_count,
                is_playable = excluded.is_playable,
                fingerprint = excluded.fingerprint,
                status = excluded.status,
                error_message = excluded.error_message,
                last_seen_at = excluded.last_seen_at,
                invalidated_at = NULL
            """
        )
        let values: [SQLiteValue] = [
            .text(assetID),
            .text(rootID),
            .text(asset.relativePath),
            .text(asset.standardizedPath),
            asset.fileIdentifier.map(SQLiteValue.text) ?? .null,
            .integer(asset.fileSize),
            .real(asset.modificationDate.timeIntervalSince1970),
            .integer(asset.durationMS),
            .integer(Int64(asset.videoTrackCount)),
            .integer(Int64(asset.audioTrackCount)),
            .integer(asset.isPlayable ? 1 : 0),
            .text(asset.fingerprint),
            .text(asset.status.rawValue),
            asset.errorMessage.map(SQLiteValue.text) ?? .null,
            .real(firstSeenAt.timeIntervalSince1970),
            .real(seenAt.timeIntervalSince1970)
        ]
        for (offset, value) in values.enumerated() {
            try statement.bind(value, at: Int32(offset + 1))
        }
        _ = try statement.step()

        if needsNewSegments, asset.status == .ready, asset.durationMS > 0,
           !(try isExcluded(assetID: assetID)) {
            try createLegacyFallbackSegments(assetID: assetID, durationMS: asset.durationMS)
        }
    }

    private func isExcluded(assetID: String) throws -> Bool {
        let statement = try connection.prepare(
            "SELECT is_excluded FROM media_asset WHERE id = ?"
        )
        try statement.bind(.text(assetID), at: 1)
        return try statement.step() && statement.integer(at: 0) != 0
    }

    /// 从媒体库移除一个根（目录或单个文件）：级联删除其全部资产、片段、
    /// 证据、向量、描述与任务。不触碰源文件。
    public func removeLibraryRoot(id: String) throws {
        let statement = try connection.prepare("DELETE FROM library_root WHERE id = ?")
        try statement.bind(.text(id), at: 1)
        _ = try statement.step()
    }

    /// 从媒体库移除单个视频：保留行作为排除标记（防止目录扫描再次纳入），
    /// 删除其全部片段与派生数据。不触碰源文件。
    public func removeAsset(assetID: String) throws {
        try connection.inTransaction {
            let mark = try connection.prepare(
                "UPDATE media_asset SET is_excluded = 1 WHERE id = ?"
            )
            try mark.bind(.text(assetID), at: 1)
            _ = try mark.step()

            // Asset-level segmentation jobs are not owned by a segment and
            // therefore do not cascade when the segment generation is deleted.
            let deleteJobs = try connection.prepare("DELETE FROM job WHERE asset_id = ?")
            try deleteJobs.bind(.text(assetID), at: 1)
            _ = try deleteJobs.step()

            let deleteSegments = try connection.prepare(
                "DELETE FROM segment WHERE asset_id = ?"
            )
            try deleteSegments.bind(.text(assetID), at: 1)
            _ = try deleteSegments.step()
        }
    }

    /// 撤销排除：视频重新进入库并重新分段。
    public func restoreAsset(assetID: String) throws {
        try connection.inTransaction {
            let statement = try connection.prepare(
                "UPDATE media_asset SET is_excluded = 0 WHERE id = ?"
            )
            try statement.bind(.text(assetID), at: 1)
            _ = try statement.step()
            let asset = try connection.prepare(
                """
                SELECT duration_ms, status,
                       (SELECT count(*) FROM segment
                        WHERE asset_id = media_asset.id AND is_active = 1)
                FROM media_asset WHERE id = ?
                """
            )
            try asset.bind(.text(assetID), at: 1)
            guard try asset.step(),
                  asset.text(at: 1) == MediaAssetStatus.ready.rawValue,
                  asset.integer(at: 0) > 0 else { return }
            let durationMS = asset.integer(at: 0)
            guard asset.integer(at: 2) == 0 else { return }
            let delete = try connection.prepare("DELETE FROM segment WHERE asset_id = ?")
            try delete.bind(.text(assetID), at: 1)
            _ = try delete.step()
            try createLegacyFallbackSegments(assetID: assetID, durationMS: durationMS)
        }
    }

    /// 重跑整个视频：把已结束的证据任务重置为待处理。
    public func requeueAssetIndexJobs(assetID: String, now: Date = Date()) throws {
        let statement = try connection.prepare(
            """
            UPDATE job
            SET status = 'pending', checkpoint_json = ?, error_message = NULL, updated_at = ?
            WHERE kind = 'index_segment'
              AND status IN ('succeeded', 'failed', 'cancelled')
              AND segment_id IN (
                SELECT id FROM segment WHERE asset_id = ? AND is_active = 1
              )
            """
        )
        try statement.bind(.text(jobCheckpoint(stage: "requeue")), at: 1)
        try statement.bind(.real(now.timeIntervalSince1970), at: 2)
        try statement.bind(.text(assetID), at: 3)
        _ = try statement.step()
    }

    /// 重跑单个片段的证据链。
    public func requeueSegmentIndexJob(segmentID: String, now: Date = Date()) throws {
        let statement = try connection.prepare(
            """
            UPDATE job
            SET status = 'pending', checkpoint_json = ?, error_message = NULL, updated_at = ?
            WHERE kind = 'index_segment'
              AND status IN ('succeeded', 'failed', 'cancelled')
              AND segment_id IN (
                SELECT id FROM segment WHERE id = ? AND is_active = 1
              )
            """
        )
        try statement.bind(.text(jobCheckpoint(stage: "requeue")), at: 1)
        try statement.bind(.real(now.timeIntervalSince1970), at: 2)
        try statement.bind(.text(segmentID), at: 3)
        _ = try statement.step()
    }

    /// 重跑单个片段的描述：丢弃缓存描述并把任务重置为待处理。
    public func requeueDescription(segmentID: String, now: Date = Date()) throws {
        try connection.inTransaction {
            let deleteDescription = try connection.prepare(
                "DELETE FROM segment_description WHERE segment_id = ?"
            )
            try deleteDescription.bind(.text(segmentID), at: 1)
            _ = try deleteDescription.step()

            let requeue = try connection.prepare(
                """
                UPDATE job
                SET status = 'pending', checkpoint_json = ?, error_message = NULL, updated_at = ?
                WHERE kind = 'describe_segment'
                  AND status IN ('succeeded', 'failed', 'cancelled')
                  AND segment_id IN (
                    SELECT id FROM segment WHERE id = ? AND is_active = 1
                  )
                """
            )
            try requeue.bind(.text(jobCheckpoint(stage: "requeue")), at: 1)
            try requeue.bind(.real(now.timeIntervalSince1970), at: 2)
            try requeue.bind(.text(segmentID), at: 3)
            _ = try requeue.step()
        }
    }

    private func jobCheckpoint(stage: String) -> String {
        let data = try? JSONSerialization.data(withJSONObject: ["stage": stage])
        return data.map { String(decoding: $0, as: UTF8.self) } ?? "{}"
    }

    private struct ExistingAsset {
        let id: String
        let fingerprint: String
        let durationMS: Int64
        let status: MediaAssetStatus
        let firstSeenAt: Date
        let segmentCount: Int
    }

    private func existingAsset(
        rootID: String,
        relativePath: String,
        fileIdentifier: String?
    ) throws -> ExistingAsset? {
        if let fileIdentifier, !fileIdentifier.isEmpty {
            let byIdentifier = try connection.prepare(
                """
                SELECT id, fingerprint, duration_ms, status, first_seen_at,
                       (SELECT count(*) FROM segment
                        WHERE asset_id = media_asset.id AND is_active = 1)
                FROM media_asset
                WHERE root_id = ? AND file_identifier = ?
                LIMIT 1
                """
            )
            try byIdentifier.bind(.text(rootID), at: 1)
            try byIdentifier.bind(.text(fileIdentifier), at: 2)
            if let existing = try existingAsset(from: byIdentifier) {
                return existing
            }
        }

        let byPath = try connection.prepare(
            """
            SELECT id, fingerprint, duration_ms, status, first_seen_at,
                   (SELECT count(*) FROM segment
                    WHERE asset_id = media_asset.id AND is_active = 1)
            FROM media_asset
            WHERE root_id = ? AND relative_path = ?
            LIMIT 1
            """
        )
        try byPath.bind(.text(rootID), at: 1)
        try byPath.bind(.text(relativePath), at: 2)
        return try existingAsset(from: byPath)
    }

    private func existingAsset(from statement: SQLiteStatement) throws -> ExistingAsset? {
        guard try statement.step(),
              let id = statement.text(at: 0),
              let fingerprint = statement.text(at: 1),
              let statusText = statement.text(at: 3),
              let status = MediaAssetStatus(rawValue: statusText) else {
            return nil
        }
        return ExistingAsset(
            id: id,
            fingerprint: fingerprint,
            durationMS: statement.integer(at: 2),
            status: status,
            firstSeenAt: Date(timeIntervalSince1970: statement.real(at: 4)),
            segmentCount: Int(statement.integer(at: 5))
        )
    }

    /// V1 compatibility only. Once a `segment_asset` job exists these ranges
    /// are ineligible for model work; they merely preserve old searchable data
    /// until a content-aware generation has been staged and activated.
    private func createLegacyFallbackSegments(assetID: String, durationMS: Int64) throws {
        let segmentLength: Int64 = 20_000
        let count = Self.legacyFallbackSegmentCount(durationMS: durationMS)
        guard count > 0 else {
            return
        }

        for ordinal in 0..<count {
            let start = Int64(ordinal) * segmentLength
            let end = min(start + segmentLength, durationMS)
            let statement = try connection.prepare(
                """
                INSERT INTO segment (
                    id, asset_id, ordinal, start_ms, end_ms, segmentation_version,
                    segmentation_run_id, is_active
                ) VALUES (?, ?, ?, ?, ?, 1, NULL, 1)
                """
            )
            try statement.bind(.text("\(assetID):v1:\(ordinal)"), at: 1)
            try statement.bind(.text(assetID), at: 2)
            try statement.bind(.integer(Int64(ordinal)), at: 3)
            try statement.bind(.integer(start), at: 4)
            try statement.bind(.integer(end), at: 5)
            _ = try statement.step()
        }
    }

    private static func legacyFallbackSegmentCount(durationMS: Int64) -> Int {
        let segmentLength: Int64 = 20_000
        guard durationMS > 0 else { return 0 }
        return Int((durationMS + segmentLength - 1) / segmentLength)
    }

    private static func migrate(_ connection: SQLiteConnection) throws {
        let version = try schemaVersion(connection)
        guard version <= 7 else {
            throw MediaDatabaseOpenError.unsupportedSchemaVersion(version)
        }
        try connection.execute("PRAGMA foreign_keys = ON")
        try connection.execute("PRAGMA journal_mode = WAL")
        try connection.execute("PRAGMA synchronous = NORMAL")
        try connection.execute(
            """
            CREATE TABLE IF NOT EXISTS library_root (
                id TEXT PRIMARY KEY,
                path TEXT NOT NULL UNIQUE,
                bookmark BLOB NOT NULL,
                is_enabled INTEGER NOT NULL DEFAULT 1 CHECK (is_enabled IN (0, 1)),
                created_at REAL NOT NULL,
                last_scan_at REAL
            );

            CREATE TABLE IF NOT EXISTS media_asset (
                id TEXT PRIMARY KEY,
                root_id TEXT NOT NULL REFERENCES library_root(id) ON DELETE CASCADE,
                relative_path TEXT NOT NULL,
                standardized_path TEXT NOT NULL,
                file_identifier TEXT,
                file_size INTEGER NOT NULL,
                modification_time REAL NOT NULL,
                duration_ms INTEGER NOT NULL DEFAULT 0,
                video_track_count INTEGER NOT NULL DEFAULT 0,
                audio_track_count INTEGER NOT NULL DEFAULT 0,
                is_playable INTEGER NOT NULL DEFAULT 0 CHECK (is_playable IN (0, 1)),
                fingerprint TEXT NOT NULL,
                status TEXT NOT NULL CHECK (status IN ('ready', 'failed', 'missing')),
                error_message TEXT,
                first_seen_at REAL NOT NULL,
                last_seen_at REAL NOT NULL,
                invalidated_at REAL,
                UNIQUE(root_id, relative_path)
            );
            CREATE INDEX IF NOT EXISTS media_asset_root_file_id
                ON media_asset(root_id, file_identifier);
            CREATE INDEX IF NOT EXISTS media_asset_fingerprint
                ON media_asset(fingerprint);

            CREATE TABLE IF NOT EXISTS segment (
                id TEXT PRIMARY KEY,
                asset_id TEXT NOT NULL REFERENCES media_asset(id) ON DELETE CASCADE,
                ordinal INTEGER NOT NULL,
                start_ms INTEGER NOT NULL,
                end_ms INTEGER NOT NULL,
                segmentation_version INTEGER NOT NULL,
                segmentation_run_id TEXT REFERENCES derivation_run(id) ON DELETE CASCADE,
                is_active INTEGER NOT NULL DEFAULT 1 CHECK (is_active IN (0, 1)),
                CHECK (start_ms >= 0 AND end_ms > start_ms),
                UNIQUE(asset_id, segmentation_version, ordinal)
            );
            CREATE TABLE IF NOT EXISTS derivation_run (
                id TEXT PRIMARY KEY,
                asset_id TEXT NOT NULL REFERENCES media_asset(id) ON DELETE CASCADE,
                kind TEXT NOT NULL,
                model_id TEXT,
                model_sha TEXT,
                runtime_version TEXT,
                parameters_json TEXT NOT NULL,
                source_fingerprint TEXT NOT NULL,
                status TEXT NOT NULL CHECK (status IN ('running', 'succeeded', 'failed', 'cancelled')),
                started_at REAL NOT NULL,
                completed_at REAL,
                error_message TEXT
            );

            CREATE TABLE IF NOT EXISTS timeline_boundary_observation (
                id TEXT PRIMARY KEY,
                derivation_run_id TEXT NOT NULL REFERENCES derivation_run(id) ON DELETE CASCADE,
                asset_id TEXT NOT NULL REFERENCES media_asset(id) ON DELETE CASCADE,
                time_ms INTEGER NOT NULL CHECK (time_ms >= 0),
                kind TEXT NOT NULL CHECK (kind IN ('visual_change', 'silence_end')),
                score REAL NOT NULL CHECK (score >= 0 AND score <= 1),
                details_json TEXT NOT NULL
            );
            CREATE INDEX IF NOT EXISTS timeline_boundary_asset_time
                ON timeline_boundary_observation(asset_id, time_ms);

            CREATE TABLE IF NOT EXISTS transcript_segment (
                id TEXT PRIMARY KEY,
                segment_id TEXT NOT NULL REFERENCES segment(id) ON DELETE CASCADE,
                derivation_run_id TEXT NOT NULL REFERENCES derivation_run(id) ON DELETE CASCADE,
                text TEXT NOT NULL,
                language TEXT,
                start_ms INTEGER NOT NULL,
                end_ms INTEGER NOT NULL,
                timing_source TEXT NOT NULL,
                CHECK (end_ms > start_ms)
            );

            CREATE TABLE IF NOT EXISTS ocr_observation (
                id TEXT PRIMARY KEY,
                segment_id TEXT NOT NULL REFERENCES segment(id) ON DELETE CASCADE,
                derivation_run_id TEXT NOT NULL REFERENCES derivation_run(id) ON DELETE CASCADE,
                text TEXT NOT NULL,
                confidence REAL NOT NULL,
                box_x REAL NOT NULL,
                box_y REAL NOT NULL,
                box_width REAL NOT NULL,
                box_height REAL NOT NULL,
                start_ms INTEGER NOT NULL,
                end_ms INTEGER NOT NULL
            );

            CREATE TABLE IF NOT EXISTS segment_frame (
                id TEXT PRIMARY KEY,
                segment_id TEXT NOT NULL REFERENCES segment(id) ON DELETE CASCADE,
                ordinal INTEGER NOT NULL,
                time_ms INTEGER NOT NULL,
                relative_path TEXT NOT NULL,
                perceptual_hash INTEGER NOT NULL,
                created_at REAL NOT NULL,
                UNIQUE(segment_id, ordinal)
            );

            CREATE TABLE IF NOT EXISTS segment_embedding (
                segment_id TEXT PRIMARY KEY REFERENCES segment(id) ON DELETE CASCADE,
                derivation_run_id TEXT NOT NULL REFERENCES derivation_run(id) ON DELETE CASCADE,
                dimension INTEGER NOT NULL,
                vector BLOB NOT NULL,
                model_id TEXT NOT NULL,
                input_version TEXT NOT NULL,
                created_at REAL NOT NULL
            );

            CREATE TABLE IF NOT EXISTS segment_description (
                segment_id TEXT PRIMARY KEY REFERENCES segment(id) ON DELETE CASCADE,
                derivation_run_id TEXT NOT NULL REFERENCES derivation_run(id) ON DELETE CASCADE,
                description_json TEXT NOT NULL,
                prompt_version TEXT NOT NULL,
                input_version TEXT NOT NULL,
                created_at REAL NOT NULL
            );

            CREATE TABLE IF NOT EXISTS job (
                id TEXT PRIMARY KEY,
                asset_id TEXT REFERENCES media_asset(id) ON DELETE CASCADE,
                segment_id TEXT REFERENCES segment(id) ON DELETE CASCADE,
                kind TEXT NOT NULL,
                status TEXT NOT NULL CHECK (status IN ('pending', 'running', 'succeeded', 'failed', 'cancelled')),
                attempt_count INTEGER NOT NULL DEFAULT 0,
                checkpoint_json TEXT,
                error_message TEXT,
                created_at REAL NOT NULL,
                updated_at REAL NOT NULL
            );
            CREATE INDEX IF NOT EXISTS job_status_kind ON job(status, kind, created_at);
            CREATE UNIQUE INDEX IF NOT EXISTS job_segment_kind
                ON job(segment_id, kind) WHERE segment_id IS NOT NULL;
            CREATE UNIQUE INDEX IF NOT EXISTS job_asset_kind
                ON job(asset_id, kind) WHERE segment_id IS NULL AND asset_id IS NOT NULL;

            CREATE VIRTUAL TABLE IF NOT EXISTS evidence_fts USING fts5(
                segment_id UNINDEXED,
                evidence_type UNINDEXED,
                evidence_id UNINDEXED,
                text,
                tokenize = 'trigram'
            );

            CREATE TRIGGER IF NOT EXISTS transcript_segment_delete_fts
            AFTER DELETE ON transcript_segment BEGIN
                DELETE FROM evidence_fts
                WHERE evidence_type = 'transcript' AND evidence_id = old.id;
            END;

            CREATE TRIGGER IF NOT EXISTS ocr_observation_delete_fts
            AFTER DELETE ON ocr_observation BEGIN
                DELETE FROM evidence_fts
                WHERE evidence_type = 'ocr' AND evidence_id = old.id;
            END;

            CREATE TRIGGER IF NOT EXISTS segment_description_delete_fts
            AFTER DELETE ON segment_description BEGIN
                DELETE FROM evidence_fts
                WHERE evidence_type = 'visual' AND segment_id = old.segment_id;
            END;

            """
        )
        if version < 7 {
            // DDL 与版本号必须一起提交。列存在检查也让曾在旧实现中断于
            // ALTER TABLE 与 user_version 之间的数据库可以安全恢复。
            try connection.inTransaction {
                if version < 2 {
                    try connection.execute("PRAGMA user_version = 2")
                }
                if version < 3 {
                    if !(try columnExists(connection, table: "library_root", column: "kind")) {
                        try connection.execute(
                            "ALTER TABLE library_root ADD COLUMN kind TEXT NOT NULL DEFAULT 'directory'"
                        )
                    }
                    try connection.execute("PRAGMA user_version = 3")
                }
                if version < 4 {
                    // 用户明确移除的视频：行保留作为排除标记，所有派生数据随 segment 删除。
                    if !(try columnExists(connection, table: "media_asset", column: "is_excluded")) {
                        try connection.execute(
                            "ALTER TABLE media_asset ADD COLUMN is_excluded INTEGER NOT NULL DEFAULT 0"
                        )
                    }
                    try connection.execute("PRAGMA user_version = 4")
                }
                if version < 5 {
                    // Version 5 used to add a global processing gate. The
                    // runtime no longer creates or consults that table; an
                    // existing legacy table is harmless and intentionally left
                    // untouched to avoid a destructive compatibility migration.
                    try connection.execute("PRAGMA user_version = 5")
                }
                if version < 6 {
                    // 新描述会在提交事务中同步更新 FTS；这里把已经保存的描述
                    // 原地补入索引，升级后无需重新调用模型。
                    try backfillVisualDescriptionFTS(connection)
                    try connection.execute("PRAGMA user_version = 6")
                }
                if version < 7 {
                    // 内容感知分片会在旧分片仍可搜索时构建新一代结果。
                    // 两列均提供安全默认值，升级后现有 V1 片段保持激活。
                    if !(try columnExists(connection, table: "segment", column: "segmentation_run_id")) {
                        try connection.execute(
                            "ALTER TABLE segment ADD COLUMN segmentation_run_id TEXT REFERENCES derivation_run(id) ON DELETE CASCADE"
                        )
                    }
                    if !(try columnExists(connection, table: "segment", column: "is_active")) {
                        try connection.execute(
                            "ALTER TABLE segment ADD COLUMN is_active INTEGER NOT NULL DEFAULT 1 CHECK (is_active IN (0, 1))"
                        )
                    }
                    try connection.execute(
                        "CREATE UNIQUE INDEX IF NOT EXISTS job_asset_kind ON job(asset_id, kind) WHERE segment_id IS NULL AND asset_id IS NOT NULL"
                    )
                    try connection.execute("PRAGMA user_version = 7")
                }
            }
        }
        // This index must be created after the V6→V7 ALTER adds `is_active`.
        // Creating it in the common bootstrap DDL would make a genuine V6
        // database fail before the migration transaction could run.
        try connection.execute(
            "CREATE INDEX IF NOT EXISTS segment_asset_active ON segment(asset_id, is_active, ordinal)"
        )
    }

    private static func backfillVisualDescriptionFTS(
        _ connection: SQLiteConnection
    ) throws {
        let query = try connection.prepare(
            "SELECT segment_id, description_json FROM segment_description ORDER BY segment_id"
        )
        var descriptions: [(segmentID: String, value: SegmentDescription)] = []
        while try query.step() {
            guard let segmentID = query.text(at: 0),
                  let json = query.text(at: 1),
                  let value = try? JSONDecoder().decode(
                      SegmentDescription.self,
                      from: Data(json.utf8)
                  ) else {
                continue
            }
            descriptions.append((segmentID, value))
        }

        try connection.execute("DELETE FROM evidence_fts WHERE evidence_type = 'visual'")
        for item in descriptions {
            for (index, value) in item.value.searchableVisualTexts.enumerated() {
                let insert = try connection.prepare(
                    """
                    INSERT INTO evidence_fts (segment_id, evidence_type, evidence_id, text)
                    VALUES (?, 'visual', ?, ?)
                    """
                )
                try insert.bind(.text(item.segmentID), at: 1)
                try insert.bind(.text("\(item.segmentID):visual:\(index)"), at: 2)
                try insert.bind(.text(value), at: 3)
                _ = try insert.step()
            }
        }
    }

    private static func columnExists(
        _ connection: SQLiteConnection,
        table: String,
        column: String
    ) throws -> Bool {
        let statement = try connection.prepare("PRAGMA table_info(\(table))")
        while try statement.step() {
            if statement.text(at: 1) == column { return true }
        }
        return false
    }

    private static func schemaVersion(_ connection: SQLiteConnection) throws -> Int64 {
        let statement = try connection.prepare("PRAGMA user_version")
        return try statement.step() ? statement.integer(at: 0) : 0
    }
}
