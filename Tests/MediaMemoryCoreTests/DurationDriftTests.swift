import Foundation
@testable import MediaMemoryCore
import XCTest

/// 时长探测漂移（同指纹）：抖动只更新字段；显著漂移挂起候选、旁路新代际
/// 修正，激活事务内落定权威时长。段 ID 以 runID 区分代际（同算法重放不冲突）。
final class DurationDriftTests: XCTestCase {
    func testJitterDriftUpdatesDurationWithoutTouchingGeneration() async throws {
        let fixture = try await DriftFixture.make(durationMS: 45_001)
        // 活动覆盖 45_001，新探测 45_600：偏差 599 ≤ 容差 → 探测抖动。
        try await fixture.rescan(durationMS: 45_600)

        let asset = try await fixture.asset()
        XCTAssertEqual(asset.durationMS, 45_600, "抖动必须立即更新权威时长")
        let segments = try await fixture.database.segments(assetID: asset.id)
        XCTAssertEqual(segments.map(\.endMS).last, 45_001, "抖动不得改动现有代际覆盖")
        try fixture.assertCandidate(nil)
    }

    func testSignificantDriftSuspendsCandidateAndKeepsGeneration() async throws {
        let fixture = try await DriftFixture.make(durationMS: 45_001)
        try await fixture.rescan(durationMS: 48_000)

        let asset = try await fixture.asset()
        XCTAssertEqual(asset.durationMS, 45_001, "显著漂移不得提前覆盖权威时长")
        try fixture.assertCandidate(48_000)
        let segments = try await fixture.database.segments(assetID: asset.id)
        XCTAssertFalse(segments.isEmpty, "显著漂移绝不先删当前可用代际")

        let progress = try await fixture.database.reconcileSegmentationJobs(
            algorithmVersion: "semantic-drift"
        )
        XCTAssertEqual(progress.pending, 1, "挂起候选必须重新触发语义分片")
    }

    func testDriftCorrectionStagesGenerationAndActivationAppliesDuration() async throws {
        let fixture = try await DriftFixture.make(durationMS: 10_000)
        try await fixture.commitActiveGeneration(segments: [.init(startMS: 0, endMS: 10_000)])
        let assetBefore = try await fixture.asset()
        XCTAssertEqual(assetBefore.durationMS, 10_000)

        // 显著漂移：10_000 → 14_000。
        try await fixture.rescan(durationMS: 14_000)
        try fixture.assertCandidate(14_000)
        _ = try await fixture.database.reconcileSegmentationJobs(algorithmVersion: "semantic-drift")
        let claim = try fixture.segmentationClaim(
            try await fixture.database.claimNextSegmentationJob()
        )
        XCTAssertEqual(claim.candidateDurationMS, 14_000, "认领必须携带候选时长")

        // 新代际与旧 ACTIVE 代际共享 10_000 边界：段 ID 以 runID 区分，
        // 不得主键冲突（原 assetID:algorithm:start:end 方案在此必炸）。
        try await fixture.database.commitSegmentation(
            claim: claim.job.claimToken,
            assetID: claim.asset.id,
            sourceFingerprint: claim.asset.fingerprint,
            algorithmVersion: "semantic-drift",
            parametersJSON: "{\"algorithm_version\":\"semantic-drift\"}",
            segments: [
                .init(startMS: 0, endMS: 10_000),
                .init(startMS: 10_000, endMS: 14_000)
            ],
            candidateDurationMS: 14_000
        )
        try fixture.assertCandidate(nil, "提交暂存后必须清除挂起标记")
        let stagedAsset = try await fixture.asset()
        XCTAssertEqual(stagedAsset.durationMS, 10_000, "激活前权威时长保持旧值")
        let stillActive = try await fixture.database.segments(assetID: claim.asset.id)
        XCTAssertEqual(stillActive.map(\.endMS), [10_000], "激活前旧代际继续服役")

        // 新代际证据补齐后激活：权威时长与活动代际同事务落定。
        try await fixture.commitEvidence(count: 2)
        let activated = try await fixture.database.activateReadySegmentation(
            assetID: claim.asset.id
        )
        XCTAssertTrue(activated)
        let corrected = try await fixture.asset()
        XCTAssertEqual(corrected.durationMS, 14_000, "激活必须落定候选时长")
        let active = try await fixture.database.segments(assetID: claim.asset.id)
        XCTAssertEqual(active.map(\.endMS), [10_000, 14_000])
    }

    func testCommitRejectsCoverageMismatchAgainstCandidate() async throws {
        let fixture = try await DriftFixture.make(durationMS: 10_000)
        try await fixture.commitActiveGeneration(segments: [.init(startMS: 0, endMS: 10_000)])
        try await fixture.rescan(durationMS: 14_000)
        _ = try await fixture.database.reconcileSegmentationJobs(algorithmVersion: "semantic-drift")
        let claim = try fixture.segmentationClaim(
            try await fixture.database.claimNextSegmentationJob()
        )

        do {
            try await fixture.database.commitSegmentation(
                claim: claim.job.claimToken,
                assetID: claim.asset.id,
                sourceFingerprint: claim.asset.fingerprint,
                algorithmVersion: "semantic-drift",
                parametersJSON: "{\"algorithm_version\":\"semantic-drift\"}",
                segments: [.init(startMS: 0, endMS: 12_000)],
                candidateDurationMS: 14_000
            )
            XCTFail("覆盖终点与候选时长不符应被拒绝")
        } catch SegmentationDatabaseError.invalidCoverage {
            // expected
        }
    }

    func testMisprobedDriftIsDismissedWithoutNewGeneration() async throws {
        let fixture = try await DriftFixture.make(durationMS: 10_000, useRealFile: true)
        let segmenter = fixture.makeSegmenter(decodedDurationMS: 10_000)
        let first = try await segmenter.runUntilIdle()
        XCTAssertEqual(first, IndexRunSummary(succeeded: 1, failed: 0))
        // 无已索引活动代际 → 首次分片在提交事务内立即激活。
        let activeBeforeDrift = try await fixture.database.segments(assetID: fixture.assetID)
        XCTAssertEqual(activeBeforeDrift.map(\.endMS), [10_000])

        // 探测漂移到 14_000，但解码时长证实旧值 → 候选是误报。
        try await fixture.rescan(durationMS: 14_000)
        try fixture.assertCandidate(14_000)
        let dismissive = fixture.makeSegmenter(decodedDurationMS: 10_050)
        let summary = try await dismissive.runUntilIdle()
        XCTAssertEqual(summary, IndexRunSummary(succeeded: 1, failed: 0))

        try fixture.assertCandidate(nil, "误报必须清除挂起标记")
        let asset = try await fixture.asset()
        XCTAssertEqual(asset.durationMS, 10_000, "误报不得改动权威时长")
        let activeAfterDismiss = try await fixture.database.segments(assetID: fixture.assetID)
        XCTAssertEqual(activeAfterDismiss.count, 1, "误报不得旁路新代际")
        XCTAssertEqual(
            try fixture.runningSegmentationRuns(),
            0,
            "误报路径不得留下 staging run"
        )
        // 不引入外来算法做 reconcile（那等价于算法升级，排队是正确行为）；
        // 直接验证任务已结、无待处理。
        let finalProgress = try await dismissive.progress()
        XCTAssertEqual(finalProgress.pending, 0, "误报结任务后不得有待处理分片任务")
        XCTAssertEqual(finalProgress.failed, 0)
    }
}

// MARK: - 夹具

private final class DriftTemporaryDirectory {
    let url: URL

    init() throws {
        url = FileManager.default.temporaryDirectory
            .appending(path: "duration-drift-tests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    deinit {
        try? FileManager.default.removeItem(at: url)
    }
}

private struct DriftFixture {
    let temporary: DriftTemporaryDirectory
    let database: MediaDatabase
    let rootID: String
    let assetID: String
    let relativePath: String
    let fingerprint: String
    let sourceURL: URL?

    static func make(durationMS: Int64, useRealFile: Bool = false) async throws -> DriftFixture {
        let temporary = try DriftTemporaryDirectory()
        let database = try MediaDatabase(url: temporary.url.appending(path: "test.sqlite"))
        let root = try await database.addLibraryRoot(
            path: temporary.url.path,
            bookmark: Data([21])
        )
        let relativePath = "drift.mp4"
        var fingerprint = "drift-fingerprint"
        var sourceURL: URL?
        if useRealFile {
            let source = temporary.url.appending(path: relativePath)
            try Data(repeating: 0x43, count: 64 * 1_024).write(to: source)
            let snapshot = try FileFingerprint.snapshot(for: source)
            fingerprint = try FileFingerprint.lightFingerprint(for: source, snapshot: snapshot)
            sourceURL = source
        }
        let fixture = DriftFixture(
            temporary: temporary,
            database: database,
            rootID: root.id,
            assetID: "",
            relativePath: relativePath,
            fingerprint: fingerprint,
            sourceURL: sourceURL
        )
        try await fixture.scan(durationMS: durationMS)
        let asset = try await fixture.asset()
        return DriftFixture(
            temporary: temporary,
            database: database,
            rootID: root.id,
            assetID: asset.id,
            relativePath: relativePath,
            fingerprint: fingerprint,
            sourceURL: sourceURL
        )
    }

    private func scannedAsset(durationMS: Int64) -> ScannedMediaAsset {
        ScannedMediaAsset(
            relativePath: relativePath,
            standardizedPath: (sourceURL?.path ?? "/offline-volume/\(relativePath)"),
            fileIdentifier: nil,
            fileSize: 1_024,
            modificationDate: Date(timeIntervalSince1970: 100),
            durationMS: durationMS,
            videoTrackCount: 1,
            audioTrackCount: 1,
            isPlayable: true,
            fingerprint: fingerprint,
            status: .ready,
            errorMessage: nil
        )
    }

    private func scan(durationMS: Int64) async throws {
        try await database.applyScan(
            rootID: rootID,
            result: MediaScanResult(
                assets: [scannedAsset(durationMS: durationMS)],
                unstableFileCount: 0,
                skippedFileCount: 0,
                errors: []
            )
        )
    }

    /// 同指纹重扫，仅时长变化。
    func rescan(durationMS: Int64) async throws {
        try await scan(durationMS: durationMS)
    }

    func asset() async throws -> MediaAssetRecord {
        let assets = try await database.mediaAssets(rootID: rootID)
        return try requireValue(assets.first)
    }

    /// 认领分片任务并直接提交。首次分片因无已索引活动代际会在提交事务内
    /// 立即激活；随后补证据，确保后续漂移代际走正常 staging 而非立即激活。
    func commitActiveGeneration(segments: [SemanticSegmentDraft]) async throws {
        _ = try await database.reconcileSegmentationJobs(algorithmVersion: "semantic-drift")
        let claim = try segmentationClaim(
            try await database.claimNextSegmentationJob()
        )
        try await database.commitSegmentation(
            claim: claim.job.claimToken,
            assetID: claim.asset.id,
            sourceFingerprint: claim.asset.fingerprint,
            algorithmVersion: "semantic-drift",
            parametersJSON: "{\"algorithm_version\":\"semantic-drift\"}",
            segments: segments
        )
        let active = try await database.segments(assetID: assetID)
        XCTAssertEqual(
            active.map(\.endMS),
            segments.map(\.endMS),
            "首代分片应在提交事务内立即激活"
        )
        try await commitEvidence(count: segments.count)
    }

    /// 为当前待建库片段提交证据（每个片段一个向量）。
    func commitEvidence(count: Int) async throws {
        for _ in 0..<count {
            try await database.reconcileIndexJobs(
                embeddingModelID: "embedding-model",
                inputVersion: "pipeline-v1"
            )
            let target = try indexClaim(try await database.claimNextIndexJob())
            try await database.commitIndexOutput(
                claim: target.job.claimToken,
                segmentID: target.segment.id,
                output: SegmentIndexOutput(
                    sourceFingerprint: target.asset.fingerprint,
                    transcripts: [],
                    ocr: [],
                    frames: [
                        .init(
                            timeMS: target.segment.startMS,
                            relativePath: "Frames/drift/\(target.segment.ordinal).jpg",
                            perceptualHash: 1
                        )
                    ],
                    embedding: EmbeddingVector(values: [0.6, 0.8], norm: 1),
                    asrModelID: "asr-model",
                    alignerModelID: "aligner-model",
                    embeddingModelID: "embedding-model",
                    runtimeVersion: "drift-test"
                ),
                inputVersion: "pipeline-v1"
            )
        }
    }

    func makeSegmenter(decodedDurationMS: Int64) -> ContentSegmenter {
        let sourceCache = LocalSourceCache(
            workRoot: temporary.url,
            minimumFreeBytes: 0,
            availableCapacity: { _ in Int64.max }
        )
        return ContentSegmenter(
            database: database,
            sourceCache: sourceCache
        ) { _, _ in
            TimelineFeatureExtractionResult(durationMS: decodedDurationMS, candidates: [])
        }
    }

    func segmentationClaim(_ claim: AssetSegmentationClaim) throws -> AssetSegmentationTarget {
        guard case let .target(value) = claim else {
            throw DriftFixtureError.emptyClaim
        }
        return value
    }

    private func indexClaim(_ claim: JobClaim) throws -> SegmentIndexTarget {
        guard case let .target(value) = claim else {
            throw DriftFixtureError.emptyClaim
        }
        return value
    }

    func assertCandidate(_ expected: Int64?, _ message: String = "") throws {
        let inspection = try SQLiteConnection(
            url: temporary.url.appending(path: "test.sqlite")
        )
        let statement = try inspection.prepare(
            "SELECT candidate_duration_ms FROM media_asset WHERE id = ?"
        )
        try statement.bind(.text(assetID), at: 1)
        guard try statement.step() else {
            return XCTFail("资产行不存在：\(message)")
        }
        let raw = statement.integer(at: 0)
        let actual = raw > 0 ? raw : nil
        XCTAssertEqual(actual, expected, message)
    }

    func runningSegmentationRuns() throws -> Int {
        let inspection = try SQLiteConnection(
            url: temporary.url.appending(path: "test.sqlite")
        )
        let statement = try inspection.prepare(
            "SELECT count(*) FROM derivation_run WHERE kind = 'segmentation' AND status = 'running'"
        )
        guard try statement.step() else { return 0 }
        return Int(statement.integer(at: 0))
    }
}

private enum DriftFixtureError: Error {
    case emptyClaim
}

private func requireValue<T>(_ value: T?) throws -> T {
    guard let value else {
        XCTFail("Optional 为空")
        throw DriftFixtureError.emptyClaim
    }
    return value
}
