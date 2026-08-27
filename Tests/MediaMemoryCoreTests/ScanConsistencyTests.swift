import Foundation
@testable import MediaMemoryCore
import XCTest

final class ScanConsistencyTests: XCTestCase {
    func testRealVersionSixSchemaMigratesLegacySegmentsToActiveVersionEight() async throws {
        let temporary = try ScanTemporaryDirectory()
        let url = temporary.url.appending(path: "real-v6.sqlite")
        do {
            let legacy = try SQLiteConnection(url: url)
            try legacy.execute(
                """
                PRAGMA foreign_keys = ON;
                CREATE TABLE library_root (
                    id TEXT PRIMARY KEY, path TEXT NOT NULL UNIQUE, bookmark BLOB NOT NULL,
                    is_enabled INTEGER NOT NULL DEFAULT 1, created_at REAL NOT NULL,
                    last_scan_at REAL, kind TEXT NOT NULL DEFAULT 'directory'
                );
                CREATE TABLE media_asset (
                    id TEXT PRIMARY KEY,
                    root_id TEXT NOT NULL REFERENCES library_root(id) ON DELETE CASCADE,
                    relative_path TEXT NOT NULL, standardized_path TEXT NOT NULL,
                    file_identifier TEXT, file_size INTEGER NOT NULL,
                    modification_time REAL NOT NULL, duration_ms INTEGER NOT NULL DEFAULT 0,
                    video_track_count INTEGER NOT NULL DEFAULT 0,
                    audio_track_count INTEGER NOT NULL DEFAULT 0,
                    is_playable INTEGER NOT NULL DEFAULT 0, fingerprint TEXT NOT NULL,
                    status TEXT NOT NULL, error_message TEXT, first_seen_at REAL NOT NULL,
                    last_seen_at REAL NOT NULL, invalidated_at REAL,
                    is_excluded INTEGER NOT NULL DEFAULT 0,
                    UNIQUE(root_id, relative_path)
                );
                CREATE TABLE derivation_run (
                    id TEXT PRIMARY KEY,
                    asset_id TEXT NOT NULL REFERENCES media_asset(id) ON DELETE CASCADE,
                    kind TEXT NOT NULL, model_id TEXT, model_sha TEXT, runtime_version TEXT,
                    parameters_json TEXT NOT NULL, source_fingerprint TEXT NOT NULL,
                    status TEXT NOT NULL, started_at REAL NOT NULL, completed_at REAL,
                    error_message TEXT
                );
                CREATE TABLE segment (
                    id TEXT PRIMARY KEY,
                    asset_id TEXT NOT NULL REFERENCES media_asset(id) ON DELETE CASCADE,
                    ordinal INTEGER NOT NULL, start_ms INTEGER NOT NULL, end_ms INTEGER NOT NULL,
                    segmentation_version INTEGER NOT NULL,
                    UNIQUE(asset_id, segmentation_version, ordinal)
                );
                CREATE TABLE job (
                    id TEXT PRIMARY KEY,
                    asset_id TEXT REFERENCES media_asset(id) ON DELETE CASCADE,
                    segment_id TEXT REFERENCES segment(id) ON DELETE CASCADE,
                    kind TEXT NOT NULL, status TEXT NOT NULL,
                    attempt_count INTEGER NOT NULL DEFAULT 0, checkpoint_json TEXT,
                    error_message TEXT, created_at REAL NOT NULL, updated_at REAL NOT NULL
                );
                INSERT INTO library_root (
                    id, path, bookmark, is_enabled, created_at, kind
                ) VALUES ('root-v6', '/tmp/v6', x'01', 1, 1, 'directory');
                INSERT INTO media_asset (
                    id, root_id, relative_path, standardized_path, file_size,
                    modification_time, duration_ms, video_track_count,
                    audio_track_count, is_playable, fingerprint, status,
                    first_seen_at, last_seen_at, is_excluded
                ) VALUES (
                    'asset-v6', 'root-v6', 'legacy.mp4', '/tmp/v6/legacy.mp4', 1,
                    1, 10000, 1, 1, 1, 'fingerprint-v6', 'ready', 1, 1, 0
                );
                INSERT INTO segment (
                    id, asset_id, ordinal, start_ms, end_ms, segmentation_version
                ) VALUES ('segment-v6', 'asset-v6', 0, 0, 10000, 1);
                PRAGMA user_version = 6;
                """
            )
        }

        var migrated: MediaDatabase? = try MediaDatabase(url: url)
        let segments = try await migrated!.segments(assetID: "asset-v6")
        XCTAssertEqual(segments.map(\.id), ["segment-v6"])
        migrated = nil

        let inspection = try SQLiteConnection(url: url)
        let version = try inspection.prepare("PRAGMA user_version")
        XCTAssertTrue(try version.step())
        XCTAssertEqual(version.integer(at: 0), 9)
        let active = try inspection.prepare(
            "SELECT is_active, segmentation_run_id FROM segment WHERE id = 'segment-v6'"
        )
        XCTAssertTrue(try active.step())
        XCTAssertEqual(active.integer(at: 0), 1)
        XCTAssertNil(active.text(at: 1))
        let foreignKeyCheck = try inspection.prepare("PRAGMA foreign_key_check")
        XCTAssertFalse(try foreignKeyCheck.step())

        migrated = try MediaDatabase(url: url)
        let reopened = try await migrated!.segments(assetID: "asset-v6")
        XCTAssertEqual(reopened.map(\.id), ["segment-v6"])
    }

    func testMigrationRecoversWhenColumnsExistBeforeVersionAdvance() async throws {
        let temporary = try ScanTemporaryDirectory()
        let url = temporary.url.appending(path: "migration.sqlite")
        do {
            let database = try MediaDatabase(url: url)
            _ = try await database.libraryRoots()
        }
        do {
            let connection = try SQLiteConnection(url: url)
            // 模拟旧实现已完成 ALTER TABLE、但尚未来得及更新 user_version 就退出。
            try connection.execute("PRAGMA user_version = 2")
        }

        let reopened = try MediaDatabase(url: url)
        let root = try await reopened.addLibraryRoot(
            path: temporary.url.path,
            bookmark: Data([9]),
            kind: .file
        )

        XCTAssertEqual(root.kind, .file)
    }

    func testUncertainScanPreservesCommittedIndexAndSameFingerprintRecoveryReusesIt() async throws {
        let temporary = try ScanTemporaryDirectory()
        let database = try MediaDatabase(url: temporary.url.appending(path: "test.sqlite"))
        let root = try await database.addLibraryRoot(
            path: temporary.url.path,
            bookmark: Data([1])
        )
        let asset = sampleAsset()
        let completeScanAt = Date(timeIntervalSince1970: 1_700_000_100)
        try await database.applyScan(
            rootID: root.id,
            result: completeResult(assets: [asset]),
            scannedAt: completeScanAt
        )
        try await database.reconcileIndexJobs(
            embeddingModelID: "embedding-model",
            inputVersion: "pipeline-v1"
        )
        guard case let .target(target) = try await database.claimNextIndexJob() else {
            return XCTFail("预期可认领建库任务")
        }
        try await database.commitIndexOutput(
            claim: target.job.claimToken,
            segmentID: target.segment.id,
            output: SegmentIndexOutput(
                sourceFingerprint: target.asset.fingerprint,
                transcripts: [
                    TranscriptSentenceDraft(
                        text: "应当保留的证据",
                        language: "Chinese",
                        startMS: 0,
                        endMS: 1_000,
                        timingSource: "forced_alignment_sentence"
                    )
                ],
                ocr: [],
                frames: [],
                embedding: EmbeddingVector(values: [1, 0], norm: 1),
                asrModelID: "asr-model",
                alignerModelID: "aligner-model",
                embeddingModelID: "embedding-model",
                runtimeVersion: "test"
            ),
            inputVersion: "pipeline-v1"
        )

        let beforeSegments = try await database.segments(assetID: target.asset.id)
        let beforeMatches = try await database.literalSearch(query: "保留")
        XCTAssertEqual(beforeMatches.count, 1)

        let uncertain = MediaScanResult(
            assets: [],
            unstableFileCount: 1,
            skippedFileCount: 0,
            errors: []
        )
        XCTAssertFalse(uncertain.isAuthoritativeComplete)
        try await database.applyScan(
            rootID: root.id,
            result: uncertain,
            scannedAt: Date(timeIntervalSince1970: 1_700_000_200)
        )

        let assetsAfterUncertainScan = try await database.mediaAssets()
        let rootsAfterUncertainScan = try await database.libraryRoots()
        let matchesAfterUncertainScan = try await database.literalSearch(query: "保留")
        let embeddingsAfterUncertainScan = try await database.storedEmbeddings(
            modelID: "embedding-model",
            inputVersion: "pipeline-v1"
        )
        XCTAssertEqual(assetsAfterUncertainScan.count, 1)
        XCTAssertEqual(rootsAfterUncertainScan.first?.lastScanAt, completeScanAt)
        XCTAssertEqual(matchesAfterUncertainScan.count, 1)
        XCTAssertEqual(embeddingsAfterUncertainScan.count, 1)

        // 只有完整扫描才可确认缺失；缺失期间保留派生数据但不参与搜索。
        try await database.applyScan(rootID: root.id, result: completeResult(assets: []))
        let availableWhileMissing = try await database.isIndexTargetAvailable(
            assetID: target.asset.id,
            sourceFingerprint: target.asset.fingerprint
        )
        XCTAssertFalse(availableWhileMissing)
        let assetsWhileMissing = try await database.mediaAssets()
        let matchesWhileMissing = try await database.literalSearch(query: "保留")
        XCTAssertTrue(assetsWhileMissing.isEmpty)
        XCTAssertTrue(matchesWhileMissing.isEmpty)

        // 同一源重新出现后直接恢复既有片段和索引，不重新建库。
        try await database.applyScan(rootID: root.id, result: completeResult(assets: [asset]))
        let availableAfterRestore = try await database.isIndexTargetAvailable(
            assetID: target.asset.id,
            sourceFingerprint: target.asset.fingerprint
        )
        XCTAssertTrue(availableAfterRestore)
        let recoveredAssets = try await database.mediaAssets()
        let recoveredSegments = try await database.segments(assetID: target.asset.id)
        let recoveredMatches = try await database.literalSearch(query: "保留")
        let recoveredEmbeddings = try await database.storedEmbeddings(
            modelID: "embedding-model",
            inputVersion: "pipeline-v1"
        )
        XCTAssertEqual(recoveredAssets.count, 1)
        XCTAssertEqual(recoveredSegments, beforeSegments)
        XCTAssertEqual(recoveredMatches.count, 1)
        XCTAssertEqual(recoveredEmbeddings.count, 1)
    }

    func testRunningClaimReturnsToQueueAcrossConfirmedMissingAndRestore() async throws {
        let temporary = try ScanTemporaryDirectory()
        let database = try MediaDatabase(url: temporary.url.appending(path: "test.sqlite"))
        let root = try await database.addLibraryRoot(
            path: temporary.url.path,
            bookmark: Data([1])
        )
        let asset = sampleAsset()
        try await database.applyScan(
            rootID: root.id,
            result: completeResult(assets: [asset])
        )
        try await database.reconcileIndexJobs(
            embeddingModelID: "embedding-model",
            inputVersion: "pipeline-v1"
        )
        guard case let .target(running) = try await database.claimNextIndexJob() else {
            return XCTFail("预期可认领建库任务")
        }
        let activeBeforeMissing = try await database.hasActiveProcessingWork(
            assetID: running.asset.id,
            requiresEvidence: true,
            requiresDescriptions: true
        )
        XCTAssertTrue(activeBeforeMissing)

        try await database.applyScan(rootID: root.id, result: completeResult(assets: []))
        let activeWhileMissing = try await database.hasActiveProcessingWork(
            assetID: running.asset.id,
            requiresEvidence: true,
            requiresDescriptions: true
        )
        XCTAssertTrue(
            activeWhileMissing,
            "资产暂时不可用时，运行中的读取任务仍必须阻止缓存清理"
        )
        do {
            try await database.commitIndexOutput(
                claim: running.job.claimToken,
                segmentID: running.segment.id,
                output: SegmentIndexOutput(
                    sourceFingerprint: running.asset.fingerprint,
                    transcripts: [],
                    ocr: [],
                    frames: [],
                    embedding: EmbeddingVector(values: [1, 0], norm: 1),
                    asrModelID: "asr-model",
                    alignerModelID: "aligner-model",
                    embeddingModelID: "embedding-model",
                    runtimeVersion: "test"
                ),
                inputVersion: "pipeline-v1"
            )
            XCTFail("缺失资产不应接受运行中任务提交")
        } catch MediaDatabaseDerivationError.missingTarget {
            // SegmentIndexer maps this state to a safe pending return.
        }
        try await database.returnIndexJobToQueue(
            claim: running.job.claimToken,
            stage: "target_unavailable"
        )
        let activeAfterReturn = try await database.hasActiveProcessingWork(
            assetID: running.asset.id,
            requiresEvidence: true,
            requiresDescriptions: true
        )
        XCTAssertFalse(
            activeAfterReturn,
            "不可用资产的运行任务退出后不应无限占用本地缓存"
        )

        try await database.applyScan(
            rootID: root.id,
            result: completeResult(assets: [asset])
        )
        let availableAfterRestore = try await database.isIndexTargetAvailable(
            assetID: running.asset.id,
            sourceFingerprint: running.asset.fingerprint
        )
        XCTAssertTrue(availableAfterRestore)
        try await database.reconcileIndexJobs(
            embeddingModelID: "embedding-model",
            inputVersion: "pipeline-v1"
        )
        guard case let .target(recovered) = try await database.claimNextIndexJob() else {
            return XCTFail("同指纹恢复后任务应可再次认领")
        }
        XCTAssertEqual(recovered.job.id, running.job.id)
        XCTAssertGreaterThan(recovered.job.attemptCount, running.job.attemptCount)
    }

    private func completeResult(assets: [ScannedMediaAsset]) -> MediaScanResult {
        MediaScanResult(
            assets: assets,
            unstableFileCount: 0,
            skippedFileCount: 0,
            errors: []
        )
    }

    private func sampleAsset() -> ScannedMediaAsset {
        ScannedMediaAsset(
            relativePath: "clip.mp4",
            standardizedPath: "/tmp/clip.mp4",
            fileIdentifier: "stable-file-id",
            fileSize: 1_024,
            modificationDate: Date(timeIntervalSince1970: 1_700_000_000),
            durationMS: 20_000,
            videoTrackCount: 1,
            audioTrackCount: 1,
            isPlayable: true,
            fingerprint: "stable-fingerprint",
            status: .ready,
            errorMessage: nil
        )
    }
}

private final class ScanTemporaryDirectory {
    let url: URL

    init() throws {
        url = FileManager.default.temporaryDirectory
            .appending(path: "media-memory-scan-consistency-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    deinit {
        try? FileManager.default.removeItem(at: url)
    }
}
