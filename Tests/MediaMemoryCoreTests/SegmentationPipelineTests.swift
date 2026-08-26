import Foundation
@testable import MediaMemoryCore
import XCTest

final class SegmentationPipelineTests: XCTestCase {
    func testSegmentationCannotAdvanceToSecondVideoWhileFirstIsRunning() async throws {
        let temporary = try SegmentationTemporaryDirectory()
        let database = try MediaDatabase(url: temporary.url.appending(path: "test.sqlite"))
        let root = try await database.addLibraryRoot(path: temporary.url.path, bookmark: Data([3]))
        try await database.applyScan(
            rootID: root.id,
            result: MediaScanResult(
                assets: [
                    scannedAsset(path: "/tmp/a.mp4", durationMS: 10_000, fingerprint: "a"),
                    scannedAsset(path: "/tmp/b.mp4", durationMS: 10_000, fingerprint: "b")
                ],
                unstableFileCount: 0,
                skippedFileCount: 0,
                errors: []
            )
        )
        _ = try await database.reconcileSegmentationJobs(algorithmVersion: "semantic-test")

        let first = try segmentationTarget(try await database.claimNextSegmentationJob())
        XCTAssertEqual(first.asset.relativePath, "a.mp4")
        let blocked = try await database.claimNextSegmentationJob()
        XCTAssertEqual(blocked, .idle)

        try await database.failSegmentationJob(claim: first.job.claimToken, message: "fixture")
        let second = try segmentationTarget(try await database.claimNextSegmentationJob())
        XCTAssertEqual(second.asset.relativePath, "b.mp4")
    }

    func testMissingDownstreamJobKeepsCurrentVideoUntilPipelineIsTerminal() async throws {
        let temporary = try SegmentationTemporaryDirectory()
        let database = try MediaDatabase(url: temporary.url.appending(path: "test.sqlite"))
        let root = try await database.addLibraryRoot(path: temporary.url.path, bookmark: Data([4]))
        try await database.applyScan(
            rootID: root.id,
            result: MediaScanResult(
                assets: [
                    scannedAsset(
                        path: "/tmp/reconciliation-window.mp4",
                        durationMS: 10_000,
                        fingerprint: "stable"
                    )
                ],
                unstableFileCount: 0,
                skippedFileCount: 0,
                errors: []
            )
        )
        _ = try await database.reconcileSegmentationJobs(algorithmVersion: "semantic-test")
        let segmentation = try segmentationTarget(try await database.claimNextSegmentationJob())
        try await database.commitSegmentation(
            claim: segmentation.job.claimToken,
            assetID: segmentation.asset.id,
            sourceFingerprint: segmentation.asset.fingerprint,
            algorithmVersion: "semantic-test",
            parametersJSON: "{\"algorithm_version\":\"semantic-test\"}",
            segments: [.init(startMS: 0, endMS: 10_000)]
        )

        let activeBeforeEvidenceReconcile = try await database.hasActiveProcessingWork(
            assetID: segmentation.asset.id,
            requiresEvidence: true,
            requiresDescriptions: true
        )
        XCTAssertTrue(
            activeBeforeEvidenceReconcile,
            "分片已提交但证据任务尚未补齐时，视频不能被判定完成"
        )

        try await database.reconcileIndexJobs(
            embeddingModelID: "embedding-model",
            inputVersion: "pipeline-v1"
        )
        let evidence = try indexTarget(try await database.claimNextIndexJob())
        try await commitIndex(database: database, target: evidence, text: "evidence")
        _ = try await database.activateReadySegmentation(assetID: segmentation.asset.id)
        let activeBeforeDescriptionReconcile = try await database.hasActiveProcessingWork(
            assetID: segmentation.asset.id,
            requiresEvidence: true,
            requiresDescriptions: true
        )
        XCTAssertTrue(
            activeBeforeDescriptionReconcile,
            "证据已提交但描述任务尚未补齐时，视频不能被判定完成"
        )

        try await database.reconcileDescribeJobs()
        let description = try indexTarget(try await database.claimNextDescribeJob())
        try await database.failIndexJob(
            claim: description.job.claimToken,
            message: "terminal fixture"
        )
        let activeAfterTerminalFailure = try await database.hasActiveProcessingWork(
            assetID: segmentation.asset.id,
            requiresEvidence: true,
            requiresDescriptions: true
        )
        XCTAssertFalse(
            activeAfterTerminalFailure,
            "描述失败也是终态，不应永久保留整段源视频"
        )
    }

    func testPlannerConfigurationChangeCreatesANewSegmentationGeneration() async throws {
        let temporary = try SegmentationTemporaryDirectory()
        let source = temporary.url.appending(path: "planner-config.bin")
        try Data("planner-config".utf8).write(to: source)
        let snapshot = try FileFingerprint.snapshot(for: source)
        let fingerprint = try FileFingerprint.lightFingerprint(for: source, snapshot: snapshot)
        let database = try MediaDatabase(url: temporary.url.appending(path: "test.sqlite"))
        let root = try await database.addLibraryRoot(path: temporary.url.path, bookmark: Data([5]))
        try await database.applyScan(
            rootID: root.id,
            result: MediaScanResult(
                assets: [scannedAsset(path: source.path, durationMS: 20_000, fingerprint: fingerprint)],
                unstableFileCount: 0,
                skippedFileCount: 0,
                errors: []
            )
        )
        let extractor: ContentSegmenter.FeatureExtractor = { _, _ in
            TimelineFeatureExtractionResult(durationMS: 20_000, candidates: [])
        }
        let sourceCache = LocalSourceCache(
            workRoot: temporary.url,
            minimumFreeBytes: 0,
            availableCapacity: { _ in Int64.max }
        )
        let first = ContentSegmenter(
            database: database,
            sourceCache: sourceCache,
            extractFeatures: extractor
        )
        let firstSummary = try await first.runUntilIdle()
        XCTAssertEqual(firstSummary.succeeded, 1)

        let changedPlanner = SemanticSegmentPlanner(
            configuration: .init(
                minimumDurationMS: 5_000,
                targetMinimumDurationMS: 9_000,
                targetMaximumDurationMS: 16_000,
                hardMaximumDurationMS: 30_000
            )
        )
        let changed = ContentSegmenter(
            database: database,
            sourceCache: sourceCache,
            planner: changedPlanner,
            extractFeatures: extractor
        )
        let progress = try await changed.prepareQueue()
        XCTAssertEqual(progress.pending, 1)
        XCTAssertEqual(progress.succeeded, 0)
    }

    func testNewAlgorithmCancelsOlderStagedGenerationAndCannotRollBackSearch() async throws {
        let temporary = try SegmentationTemporaryDirectory()
        let database = try MediaDatabase(url: temporary.url.appending(path: "test.sqlite"))
        let root = try await database.addLibraryRoot(path: temporary.url.path, bookmark: Data([7]))
        try await database.applyScan(
            rootID: root.id,
            result: MediaScanResult(
                assets: [scannedAsset(path: "/tmp/upgrade.mp4", durationMS: 40_000, fingerprint: "stable")],
                unstableFileCount: 0,
                skippedFileCount: 0,
                errors: []
            )
        )
        try await database.reconcileIndexJobs(
            embeddingModelID: "embedding-model",
            inputVersion: "pipeline-v1"
        )
        for ordinal in 0..<2 {
            let legacy = try indexTarget(try await database.claimNextIndexJob())
            try await commitIndex(database: database, target: legacy, text: "legacy \(ordinal)")
        }
        let assets = try await database.mediaAssets()
        let asset = try XCTUnwrap(assets.first)

        _ = try await database.reconcileSegmentationJobs(algorithmVersion: "semantic-v2")
        let v2Claim = try segmentationTarget(try await database.claimNextSegmentationJob())
        try await database.commitSegmentation(
            claim: v2Claim.job.claimToken,
            assetID: asset.id,
            sourceFingerprint: asset.fingerprint,
            algorithmVersion: "semantic-v2",
            parametersJSON: "{\"algorithm_version\":\"semantic-v2\"}",
            segments: [.init(startMS: 0, endMS: 20_000), .init(startMS: 20_000, endMS: 40_000)]
        )
        try await database.reconcileIndexJobs(
            embeddingModelID: "embedding-model",
            inputVersion: "pipeline-v1"
        )
        let staleV2IndexClaim = try indexTarget(try await database.claimNextIndexJob())

        _ = try await database.reconcileSegmentationJobs(algorithmVersion: "semantic-v3")
        let v3Claim = try segmentationTarget(try await database.claimNextSegmentationJob())
        try await database.commitSegmentation(
            claim: v3Claim.job.claimToken,
            assetID: asset.id,
            sourceFingerprint: asset.fingerprint,
            algorithmVersion: "semantic-v3",
            parametersJSON: "{\"algorithm_version\":\"semantic-v3\"}",
            segments: [
                .init(startMS: 0, endMS: 10_000),
                .init(startMS: 10_000, endMS: 25_000),
                .init(startMS: 25_000, endMS: 40_000)
            ]
        )

        do {
            try await commitIndex(database: database, target: staleV2IndexClaim, text: "stale v2")
            XCTFail("被新算法取代的旧代际认领不应再提交")
        } catch MediaDatabaseDerivationError.staleClaim {
            // expected
        }

        try await database.reconcileIndexJobs(
            embeddingModelID: "embedding-model",
            inputVersion: "pipeline-v1"
        )
        for ordinal in 0..<3 {
            let v3 = try indexTarget(try await database.claimNextIndexJob())
            try await commitIndex(database: database, target: v3, text: "v3 \(ordinal)")
        }
        let activatedV3 = try await database.activateReadySegmentation(assetID: asset.id)
        XCTAssertTrue(activatedV3)
        let activeStarts = try await database.segments(assetID: asset.id).map(\.startMS)
        XCTAssertEqual(activeStarts, [0, 10_000, 25_000])
        let activatedAgain = try await database.activateReadySegmentation(assetID: asset.id)
        XCTAssertFalse(activatedAgain)
        let stillActiveStarts = try await database.segments(assetID: asset.id).map(\.startMS)
        XCTAssertEqual(stillActiveStarts, [0, 10_000, 25_000])

        let inspection = try SQLiteConnection(url: temporary.url.appending(path: "test.sqlite"))
        let retained = try inspection.prepare(
            """
            SELECT start_ms, segmentation_run_id
            FROM segment
            WHERE asset_id = ? AND is_active = 0
            ORDER BY ordinal
            """
        )
        try retained.bind(.text(asset.id), at: 1)
        var retainedStarts: [Int64] = []
        var retainedRunIDs: [String?] = []
        while try retained.step() {
            retainedStarts.append(retained.integer(at: 0))
            retainedRunIDs.append(retained.text(at: 1))
        }
        XCTAssertEqual(retainedStarts, [0, 20_000], "上一代必须是真正活动过的 V1，而非取消的 V2")
        XCTAssertTrue(retainedRunIDs.allSatisfy { $0 == nil })
    }

    func testRemovingAssetDeletesAssetLevelSegmentationJob() async throws {
        let temporary = try SegmentationTemporaryDirectory()
        let database = try MediaDatabase(url: temporary.url.appending(path: "test.sqlite"))
        let root = try await database.addLibraryRoot(path: temporary.url.path, bookmark: Data([6]))
        try await database.applyScan(
            rootID: root.id,
            result: MediaScanResult(
                assets: [scannedAsset(path: "/tmp/remove.mp4", durationMS: 10_000, fingerprint: "stable")],
                unstableFileCount: 0,
                skippedFileCount: 0,
                errors: []
            )
        )
        let assets = try await database.mediaAssets()
        let asset = try XCTUnwrap(assets.first)
        let queued = try await database.reconcileSegmentationJobs(algorithmVersion: "semantic-test")
        XCTAssertEqual(queued.pending, 1)

        try await database.removeAsset(assetID: asset.id)
        let progress = try await database.segmentationProgress()
        XCTAssertEqual(progress.total, 0)
        let claim = try await database.claimNextSegmentationJob()
        XCTAssertEqual(claim, .idle)
    }

    func testSourceChangeRequeuesFailedSegmentationForNewFingerprint() async throws {
        let temporary = try SegmentationTemporaryDirectory()
        let database = try MediaDatabase(url: temporary.url.appending(path: "test.sqlite"))
        let root = try await database.addLibraryRoot(path: temporary.url.path, bookmark: Data([8]))
        try await database.applyScan(
            rootID: root.id,
            result: MediaScanResult(
                assets: [scannedAsset(path: "/tmp/source-change.mp4", durationMS: 10_000, fingerprint: "old")],
                unstableFileCount: 0,
                skippedFileCount: 0,
                errors: []
            )
        )
        _ = try await database.reconcileSegmentationJobs(algorithmVersion: "semantic-test")
        let stale = try segmentationTarget(try await database.claimNextSegmentationJob())

        try await database.applyScan(
            rootID: root.id,
            result: MediaScanResult(
                assets: [scannedAsset(path: "/tmp/source-change.mp4", durationMS: 11_000, fingerprint: "new")],
                unstableFileCount: 0,
                skippedFileCount: 0,
                errors: []
            )
        )
        try await database.failSegmentationJob(
            claim: stale.job.claimToken,
            message: "source changed"
        )
        let reconciled = try await database.reconcileSegmentationJobs(
            algorithmVersion: "semantic-test"
        )
        XCTAssertEqual(reconciled.pending, 1)
        XCTAssertEqual(reconciled.failed, 0)
        let refreshed = try segmentationTarget(try await database.claimNextSegmentationJob())
        XCTAssertEqual(refreshed.asset.fingerprint, "new")
        XCTAssertEqual(refreshed.asset.durationMS, 11_000)
    }

    func testFailedSegmentationStaysFailedUntilExplicitRetry() async throws {
        let temporary = try SegmentationTemporaryDirectory()
        let source = temporary.url.appending(path: "failure.bin")
        try Data("failure-fixture".utf8).write(to: source)
        let snapshot = try FileFingerprint.snapshot(for: source)
        let fingerprint = try FileFingerprint.lightFingerprint(for: source, snapshot: snapshot)
        let database = try MediaDatabase(url: temporary.url.appending(path: "test.sqlite"))
        let root = try await database.addLibraryRoot(path: temporary.url.path, bookmark: Data([9]))
        try await database.applyScan(
            rootID: root.id,
            result: MediaScanResult(
                assets: [scannedAsset(path: source.path, durationMS: 10_000, fingerprint: fingerprint)],
                unstableFileCount: 0,
                skippedFileCount: 0,
                errors: []
            )
        )
        let sourceCache = LocalSourceCache(
            workRoot: temporary.url,
            minimumFreeBytes: 0,
            availableCapacity: { _ in Int64.max }
        )
        let segmenter = ContentSegmenter(database: database, sourceCache: sourceCache) { _, _ in
            throw SegmentationFixtureError.detectorFailed
        }

        let first = try await segmenter.runUntilIdle()
        let failedProgress = try await segmenter.progress()
        XCTAssertEqual(first, IndexRunSummary(succeeded: 0, failed: 1))
        XCTAssertEqual(failedProgress.failed, 1)

        let second = try await segmenter.runUntilIdle()
        let preservedProgress = try await segmenter.progress()
        XCTAssertEqual(second, IndexRunSummary(succeeded: 0, failed: 0))
        XCTAssertEqual(preservedProgress.failed, 1)
        XCTAssertEqual(preservedProgress.pending, 0)

        try await database.reconcileIndexJobs(
            embeddingModelID: "embedding-model",
            inputVersion: "pipeline-v1"
        )
        let blockedLegacy = try await database.indexingProgress()
        XCTAssertEqual(blockedLegacy.total, 0, "分片失败时也不能退回固定20秒模型链")
    }

    func testContentSegmentationBlocksLegacyIndexingAndCreatesVariableGeneration() async throws {
        let temporary = try SegmentationTemporaryDirectory()
        let source = temporary.url.appending(path: "clip.bin")
        try Data("read-only-media-fixture".utf8).write(to: source)
        let snapshot = try FileFingerprint.snapshot(for: source)
        let fingerprint = try FileFingerprint.lightFingerprint(for: source, snapshot: snapshot)
        let database = try MediaDatabase(url: temporary.url.appending(path: "test.sqlite"))
        let root = try await database.addLibraryRoot(path: temporary.url.path, bookmark: Data([1]))
        try await database.applyScan(
            rootID: root.id,
            result: MediaScanResult(
                assets: [
                    scannedAsset(
                        path: source.path,
                        durationMS: 45_000,
                        fingerprint: fingerprint
                    )
                ],
                unstableFileCount: 0,
                skippedFileCount: 0,
                errors: []
            )
        )

        let sourceCache = LocalSourceCache(
            workRoot: temporary.url,
            minimumFreeBytes: 0,
            availableCapacity: { _ in Int64.max }
        )
        let segmenter = ContentSegmenter(database: database, sourceCache: sourceCache) { _, _ in
            TimelineFeatureExtractionResult(
                durationMS: 45_000,
                candidates: [
                    .init(
                        timeMS: 9_000,
                        evidence: .visualChange(score: 0.9, previousSampleTimeMS: 8_500)
                    ),
                    .init(
                        timeMS: 21_000,
                        evidence: .silenceEnd(startTimeMS: 19_000, durationMS: 2_000)
                    ),
                    .init(
                        timeMS: 34_000,
                        evidence: .visualChange(score: 0.8, previousSampleTimeMS: 33_500)
                    )
                ]
            )
        }
        let queued = try await segmenter.prepareQueue()
        XCTAssertEqual(queued.pending, 1)
        let assetsBeforePlanning = try await database.mediaAssets()
        let assetBeforePlanning = try XCTUnwrap(assetsBeforePlanning.first)
        let fallbackBeforePlanning = try await database.segments(assetID: assetBeforePlanning.id)
        XCTAssertTrue(fallbackBeforePlanning.isEmpty, "没有旧索引的新视频不应保留固定20秒占位片段")

        // The scan-time V1 fallback must never start model work while semantic
        // segmentation for this asset is pending.
        try await database.reconcileIndexJobs(
            embeddingModelID: "embedding-model",
            inputVersion: "pipeline-v1"
        )
        let blockedProgress = try await database.indexingProgress()
        XCTAssertEqual(blockedProgress.total, 0)

        let summary = try await segmenter.runUntilIdle()
        XCTAssertEqual(summary, IndexRunSummary(succeeded: 1, failed: 0))
        let assets = try await database.mediaAssets()
        let asset = try XCTUnwrap(assets.first)
        let semantic = try await database.segments(assetID: asset.id)
        XCTAssertEqual(semantic.map(\.startMS), [0, 9_000, 21_000, 34_000])
        XCTAssertEqual(semantic.map(\.endMS), [9_000, 21_000, 34_000, 45_000])
        XCTAssertTrue(semantic.allSatisfy { $0.segmentationVersion == 2 })
        let observations = try await database.activeTimelineBoundaryObservations(assetID: asset.id)
        XCTAssertEqual(observations.map(\.timeMS), [9_000, 21_000, 34_000])
        XCTAssertEqual(observations.map(\.kind), [.visualChange, .silenceEnd, .visualChange])

        try await database.reconcileIndexJobs(
            embeddingModelID: "embedding-model",
            inputVersion: "pipeline-v1"
        )
        let semanticProgress = try await database.indexingProgress()
        XCTAssertEqual(semanticProgress.pending, 4)
    }

    func testSearchKeepsOldGenerationUntilNewEmbeddingsAreCompleteThenSwitchesAtomically() async throws {
        let temporary = try SegmentationTemporaryDirectory()
        let database = try MediaDatabase(url: temporary.url.appending(path: "test.sqlite"))
        let root = try await database.addLibraryRoot(path: temporary.url.path, bookmark: Data([2]))
        try await database.applyScan(
            rootID: root.id,
            result: MediaScanResult(
                assets: [
                    scannedAsset(
                        path: "/tmp/legacy.mp4",
                        durationMS: 40_000,
                        fingerprint: "stable-fingerprint"
                    )
                ],
                unstableFileCount: 0,
                skippedFileCount: 0,
                errors: []
            )
        )

        try await database.reconcileIndexJobs(
            embeddingModelID: "embedding-model",
            inputVersion: "pipeline-v1"
        )
        for ordinal in 0..<2 {
            let target = try indexTarget(try await database.claimNextIndexJob())
            try await commitIndex(
                database: database,
                target: target,
                text: ordinal == 0 ? "旧代际仍然可搜索" : "旧代际第二段"
            )
        }
        let assets = try await database.mediaAssets()
        let asset = try XCTUnwrap(assets.first)
        let legacyIDs = try await database.segments(assetID: asset.id).map(\.id)
        let initialMatches = try await database.literalSearch(query: "旧代际")
        XCTAssertEqual(initialMatches.count, 2)

        _ = try await database.reconcileSegmentationJobs(algorithmVersion: "semantic-test-v2")
        let segmentationTarget = try segmentationTarget(
            try await database.claimNextSegmentationJob()
        )
        try await database.commitSegmentation(
            claim: segmentationTarget.job.claimToken,
            assetID: asset.id,
            sourceFingerprint: asset.fingerprint,
            algorithmVersion: "semantic-test-v2",
            parametersJSON: "{\"algorithm_version\":\"semantic-test-v2\"}",
            segments: [
                .init(startMS: 0, endMS: 12_000),
                .init(startMS: 12_000, endMS: 27_000),
                .init(startMS: 27_000, endMS: 40_000)
            ]
        )
        try await database.reconcileIndexJobs(
            embeddingModelID: "embedding-model",
            inputVersion: "pipeline-v1"
        )

        let stagedActiveIDs = try await database.segments(assetID: asset.id).map(\.id)
        let stagedMatches = try await database.literalSearch(query: "旧代际")
        XCTAssertEqual(stagedActiveIDs, legacyIDs)
        XCTAssertEqual(stagedMatches.count, 2)

        for ordinal in 0..<3 {
            let target = try indexTarget(try await database.claimNextIndexJob())
            try await commitIndex(
                database: database,
                target: target,
                text: "新代际片段\(ordinal + 1)"
            )
            if ordinal < 2 {
                let activated = try await database.activateReadySegmentation(assetID: asset.id)
                let currentIDs = try await database.segments(assetID: asset.id).map(\.id)
                XCTAssertFalse(activated)
                XCTAssertEqual(currentIDs, legacyIDs)
            }
        }

        let activated = try await database.activateReadySegmentation(assetID: asset.id)
        XCTAssertTrue(activated)
        let active = try await database.segments(assetID: asset.id)
        XCTAssertEqual(active.map(\.startMS), [0, 12_000, 27_000])
        XCTAssertEqual(active.map(\.endMS), [12_000, 27_000, 40_000])
        let oldMatches = try await database.literalSearch(query: "旧代际")
        let newMatches = try await database.literalSearch(query: "新代际")
        let switchedProgress = try await database.indexingProgress()
        XCTAssertTrue(oldMatches.isEmpty)
        XCTAssertEqual(newMatches.count, 3)
        XCTAssertEqual(switchedProgress.succeeded, 3)
    }

    func testOldVisualDescriptionRemainsSearchableUntilActiveDescriptionsAreComplete() async throws {
        let temporary = try SegmentationTemporaryDirectory()
        let database = try MediaDatabase(url: temporary.url.appending(path: "test.sqlite"))
        let root = try await database.addLibraryRoot(path: temporary.url.path, bookmark: Data([3]))
        try await database.applyScan(
            rootID: root.id,
            result: MediaScanResult(
                assets: [scannedAsset(path: "/tmp/visual-fallback.mp4", durationMS: 40_000, fingerprint: "stable")],
                unstableFileCount: 0,
                skippedFileCount: 0,
                errors: []
            )
        )
        try await database.reconcileIndexJobs(
            embeddingModelID: "embedding-model",
            inputVersion: "pipeline-v1"
        )
        for ordinal in 0..<2 {
            let legacy = try indexTarget(try await database.claimNextIndexJob())
            try await commitIndex(database: database, target: legacy, text: "legacy transcript \(ordinal)")
            if ordinal == 0 {
                try await saveDescription(
                    database: database,
                    segment: legacy.segment,
                    asset: legacy.asset,
                    summary: "violetumbrella"
                )
            }
        }
        let assets = try await database.mediaAssets()
        let asset = try XCTUnwrap(assets.first)

        _ = try await database.reconcileSegmentationJobs(algorithmVersion: "semantic-v2")
        let segmentation = try segmentationTarget(try await database.claimNextSegmentationJob())
        try await database.commitSegmentation(
            claim: segmentation.job.claimToken,
            assetID: asset.id,
            sourceFingerprint: asset.fingerprint,
            algorithmVersion: "semantic-v2",
            parametersJSON: "{\"algorithm_version\":\"semantic-v2\"}",
            segments: [
                .init(startMS: 0, endMS: 12_000),
                .init(startMS: 12_000, endMS: 27_000),
                .init(startMS: 27_000, endMS: 40_000)
            ]
        )
        try await database.reconcileIndexJobs(
            embeddingModelID: "embedding-model",
            inputVersion: "pipeline-v1"
        )
        for ordinal in 0..<3 {
            let current = try indexTarget(try await database.claimNextIndexJob())
            try await commitIndex(database: database, target: current, text: "current transcript \(ordinal)")
        }
        let activated = try await database.activateReadySegmentation(assetID: asset.id)
        XCTAssertTrue(activated)

        let fallback = try await database.literalSearch(query: "violetumbrella")
        XCTAssertEqual(fallback.count, 1)
        XCTAssertEqual(fallback.first?.evidence.kind, .visual)
        let fallbackSegmentID = try XCTUnwrap(fallback.first?.segmentID)
        let fallbackContext = try await database.searchContext(segmentID: fallbackSegmentID)
        XCTAssertNotNil(fallbackContext)

        let activeSegments = try await database.segments(assetID: asset.id)
        for segment in activeSegments {
            try await saveDescription(
                database: database,
                segment: segment,
                asset: asset,
                summary: "current visual \(segment.ordinal)"
            )
        }
        let afterDescriptions = try await database.literalSearch(query: "violetumbrella")
        XCTAssertTrue(afterDescriptions.isEmpty)
    }

    private func scannedAsset(
        path: String,
        durationMS: Int64,
        fingerprint: String
    ) -> ScannedMediaAsset {
        ScannedMediaAsset(
            relativePath: (path as NSString).lastPathComponent,
            standardizedPath: path,
            fileIdentifier: "segmentation-\((path as NSString).lastPathComponent)",
            fileSize: 1_024,
            modificationDate: Date(timeIntervalSince1970: 1_700_000_000),
            durationMS: durationMS,
            videoTrackCount: 1,
            audioTrackCount: 1,
            isPlayable: true,
            fingerprint: fingerprint,
            status: .ready,
            errorMessage: nil
        )
    }

    private func segmentationTarget(
        _ claim: AssetSegmentationClaim
    ) throws -> AssetSegmentationTarget {
        guard case let .target(target) = claim else {
            throw XCTSkip("预期可认领分片任务")
        }
        return target
    }

    private func indexTarget(_ claim: JobClaim) throws -> SegmentIndexTarget {
        guard case let .target(target) = claim else {
            throw XCTSkip("预期可认领建库任务")
        }
        return target
    }

    private func commitIndex(
        database: MediaDatabase,
        target: SegmentIndexTarget,
        text: String
    ) async throws {
        try await database.commitIndexOutput(
            claim: target.job.claimToken,
            segmentID: target.segment.id,
            output: SegmentIndexOutput(
                sourceFingerprint: target.asset.fingerprint,
                transcripts: [
                    .init(
                        text: text,
                        language: "Chinese",
                        startMS: target.segment.startMS,
                        endMS: min(target.segment.endMS, target.segment.startMS + 1_000),
                        timingSource: "forced_alignment_sentence"
                    )
                ],
                ocr: [],
                frames: [
                    .init(
                        timeMS: target.segment.startMS,
                        relativePath: "Frames/segmentation/\(target.segment.ordinal).jpg",
                        perceptualHash: UInt64(target.segment.ordinal + 1)
                    )
                ],
                embedding: EmbeddingVector(values: [0.6, 0.8], norm: 1),
                asrModelID: "asr-model",
                alignerModelID: "aligner-model",
                embeddingModelID: "embedding-model",
                runtimeVersion: "test"
            ),
            inputVersion: "pipeline-v1"
        )
    }

    private func saveDescription(
        database: MediaDatabase,
        segment: SegmentRecord,
        asset: MediaAssetRecord,
        summary: String
    ) async throws {
        let revisionValue = try await database.descriptionInputRevision(segmentID: segment.id)
        let revision = try XCTUnwrap(revisionValue)
        try await database.saveDescription(
            segmentID: segment.id,
            sourceFingerprint: asset.fingerprint,
            expectedInputRevision: revision,
            modelID: "description-model",
            runtimeVersion: "test",
            promptVersion: "prompt-v1",
            inputVersion: "description-v1",
            description: SegmentDescription(
                summary: summary,
                visibleDetails: [],
                uncertainty: []
            )
        )
    }
}

private enum SegmentationFixtureError: Error {
    case detectorFailed
}

private final class SegmentationTemporaryDirectory {
    let url: URL

    init() throws {
        url = FileManager.default.temporaryDirectory
            .appending(path: "segmentation-tests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    deinit {
        try? FileManager.default.removeItem(at: url)
    }
}
