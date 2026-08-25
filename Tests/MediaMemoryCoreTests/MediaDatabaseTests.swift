import Foundation
@testable import MediaMemoryCore
import XCTest

final class MediaDatabaseTests: XCTestCase {
    func testReadOnlyConnectionSeesWriterCommitsAndRejectsMutation() async throws {
        let temporary = try TemporaryDirectory()
        let url = temporary.url.appending(path: "test.sqlite")
        let writer = try MediaDatabase(url: url)
        _ = try await writer.addLibraryRoot(
            path: temporary.url.appending(path: "one").path,
            bookmark: Data([1])
        )
        let reader = try MediaDatabase(readOnlyURL: url)
        let initialRoots = try await reader.libraryRoots()
        XCTAssertEqual(initialRoots.count, 1)
        let initialVersion = try await reader.dataVersion()

        _ = try await writer.addLibraryRoot(
            path: temporary.url.appending(path: "two").path,
            bookmark: Data([2])
        )
        let updatedSnapshot = try await reader.librarySnapshot()
        let updatedVersion = try await reader.dataVersion()
        XCTAssertEqual(updatedSnapshot.roots.count, 2)
        XCTAssertNotEqual(updatedVersion, initialVersion)

        do {
            _ = try await reader.addLibraryRoot(
                path: temporary.url.appending(path: "forbidden").path,
                bookmark: Data([3])
            )
            XCTFail("只读连接不应允许写入")
        } catch is SQLiteFailure {
            // Expected: SQLite enforces the App/search read boundary.
        }
    }

    func testRefusesToDowngradeANewerDatabase() throws {
        let temporary = try TemporaryDirectory()
        let url = temporary.url.appending(path: "future.sqlite")
        do {
            let connection = try SQLiteConnection(url: url)
            try connection.execute("PRAGMA user_version = 99")
        }
        XCTAssertThrowsError(try MediaDatabase(url: url)) { error in
            XCTAssertEqual(
                error as? MediaDatabaseOpenError,
                .unsupportedSchemaVersion(99)
            )
        }
    }

    func testVersionSixMigrationBackfillsExistingVisualDescriptions() async throws {
        let temporary = try TemporaryDirectory()
        let url = temporary.url.appending(path: "legacy-v5.sqlite")
        var database: MediaDatabase? = try MediaDatabase(url: url)
        let root = try await database!.addLibraryRoot(
            path: temporary.url.path,
            bookmark: Data([6])
        )
        try await database!.applyScan(
            rootID: root.id,
            result: MediaScanResult(
                assets: [sampleAsset(relativePath: "legacy.mp4", durationMS: 10_000)],
                unstableFileCount: 0,
                skippedFileCount: 0,
                errors: []
            )
        )
        try await database!.reconcileIndexJobs(
            embeddingModelID: "embedding-model",
            inputVersion: "pipeline-v1"
        )
        let target = try unwrapTarget(try await database!.claimNextIndexJob())
        try await database!.commitIndexOutput(
            claim: target.job.claimToken,
            segmentID: target.segment.id,
            output: testIndexOutput(
                fingerprint: target.asset.fingerprint,
                framePath: "Frames/legacy/00.jpg"
            ),
            inputVersion: "pipeline-v1"
        )
        let revisionValue = try await database!.descriptionInputRevision(segmentID: target.segment.id)
        let revision = try XCTUnwrap(revisionValue)
        try await database!.saveDescription(
            segmentID: target.segment.id,
            sourceFingerprint: target.asset.fingerprint,
            expectedInputRevision: revision,
            modelID: "description-model",
            runtimeVersion: "test",
            promptVersion: "prompt-v1",
            inputVersion: "input-v1",
            description: SegmentDescription(
                summary: "画面里有一座绿色拱门。",
                visibleDetails: [],
                uncertainty: []
            )
        )
        database = nil

        do {
            let legacy = try SQLiteConnection(url: url)
            try legacy.execute("DELETE FROM evidence_fts WHERE evidence_type = 'visual'")
            try legacy.execute("PRAGMA user_version = 5")
        }

        let migrated = try MediaDatabase(url: url)
        let matches = try await migrated.literalSearch(query: "绿色拱门")
        XCTAssertEqual(matches.first?.segmentID, target.segment.id)
        XCTAssertEqual(matches.first?.evidence.kind, .visual)
    }

    func testScanCreatesStableAssetAndLegacyFallbackSegments() async throws {
        let temporary = try TemporaryDirectory()
        let database = try MediaDatabase(url: temporary.url.appending(path: "test.sqlite"))
        let root = try await database.addLibraryRoot(
            path: temporary.url.path,
            bookmark: Data([1, 2, 3])
        )
        let first = sampleAsset(relativePath: "clip.mp4", durationMS: 45_001)

        try await database.applyScan(
            rootID: root.id,
            result: MediaScanResult(
                assets: [first],
                unstableFileCount: 0,
                skippedFileCount: 0,
                errors: []
            )
        )

        let assets = try await database.mediaAssets(rootID: root.id)
        XCTAssertEqual(assets.count, 1)
        let segments = try await database.segments(assetID: try XCTUnwrap(assets.first?.id))
        XCTAssertEqual(segments.map(\.startMS), [0, 20_000, 40_000])
        XCTAssertEqual(segments.map(\.endMS), [20_000, 40_000, 45_001])

        try await database.applyScan(
            rootID: root.id,
            result: MediaScanResult(
                assets: [first],
                unstableFileCount: 0,
                skippedFileCount: 0,
                errors: []
            )
        )
        let rescanned = try await database.mediaAssets(rootID: root.id)
        let stableSegments = try await database.segments(assetID: try XCTUnwrap(rescanned.first?.id))
        XCTAssertEqual(stableSegments.map(\.id), segments.map(\.id))
    }

    func testMoveKeepsAssetIdentityWhenFileIdentifierIsStable() async throws {
        let temporary = try TemporaryDirectory()
        let database = try MediaDatabase(url: temporary.url.appending(path: "test.sqlite"))
        let root = try await database.addLibraryRoot(
            path: temporary.url.path,
            bookmark: Data([4, 5, 6])
        )
        let original = sampleAsset(relativePath: "before.mp4", durationMS: 10_000)
        try await database.applyScan(
            rootID: root.id,
            result: MediaScanResult(
                assets: [original], unstableFileCount: 0, skippedFileCount: 0, errors: []
            )
        )
        let originalAssets = try await database.mediaAssets(rootID: root.id)
        let originalID = try XCTUnwrap(originalAssets.first?.id)

        let moved = sampleAsset(relativePath: "folder/after.mp4", durationMS: 10_000)
        try await database.applyScan(
            rootID: root.id,
            result: MediaScanResult(
                assets: [moved], unstableFileCount: 0, skippedFileCount: 0, errors: []
            )
        )

        let assets = try await database.mediaAssets(rootID: root.id)
        XCTAssertEqual(assets.count, 1)
        XCTAssertEqual(assets.first?.id, originalID)
        XCTAssertEqual(assets.first?.relativePath, "folder/after.mp4")
    }

    func testSamePathKeepsIdentityWhenFileIdentifierChanges() async throws {
        let temporary = try TemporaryDirectory()
        let database = try MediaDatabase(url: temporary.url.appending(path: "test.sqlite"))
        let root = try await database.addLibraryRoot(
            path: temporary.url.path,
            bookmark: Data([11])
        )
        let original = sampleAsset(relativePath: "clip.mp4", durationMS: 10_000)
        try await database.applyScan(
            rootID: root.id,
            result: MediaScanResult(
                assets: [original], unstableFileCount: 0, skippedFileCount: 0, errors: []
            )
        )
        let originalAssets = try await database.mediaAssets()
        let originalID = try XCTUnwrap(originalAssets.first?.id)
        let changed = ScannedMediaAsset(
            relativePath: "clip.mp4",
            standardizedPath: "/tmp/clip.mp4",
            fileIdentifier: "replacement-file-id",
            fileSize: 2_048,
            modificationDate: Date(timeIntervalSince1970: 1_700_000_100),
            durationMS: 12_000,
            videoTrackCount: 1,
            audioTrackCount: 1,
            isPlayable: true,
            fingerprint: "replacement-fingerprint",
            status: .ready,
            errorMessage: nil
        )
        try await database.applyScan(
            rootID: root.id,
            result: MediaScanResult(
                assets: [changed], unstableFileCount: 0, skippedFileCount: 0, errors: []
            )
        )
        let rescanned = try await database.mediaAssets()
        XCTAssertEqual(rescanned.count, 1)
        XCTAssertEqual(rescanned.first?.id, originalID)
        XCTAssertEqual(rescanned.first?.fingerprint, "replacement-fingerprint")
    }

    func testOnlineReconcilePreservesRunningJobAndExplicitRecoveryInvalidatesOldClaim() async throws {
        let temporary = try TemporaryDirectory()
        let database = try MediaDatabase(url: temporary.url.appending(path: "test.sqlite"))
        let root = try await database.addLibraryRoot(
            path: temporary.url.path,
            bookmark: Data([7, 8, 9])
        )
        try await database.applyScan(
            rootID: root.id,
            result: MediaScanResult(
                assets: [sampleAsset(relativePath: "clip.mp4", durationMS: 45_001)],
                unstableFileCount: 0,
                skippedFileCount: 0,
                errors: []
            )
        )

        try await database.reconcileIndexJobs(
            embeddingModelID: "embedding-model",
            inputVersion: "pipeline-v1"
        )
        var progress = try await database.indexingProgress()
        XCTAssertEqual(progress.total, 3)
        XCTAssertEqual(progress.pending, 3)

        let interrupted = try unwrapTarget(try await database.claimNextIndexJob())
        XCTAssertEqual(interrupted.job.status, .running)
        try await database.reconcileIndexJobs(
            embeddingModelID: "embedding-model",
            inputVersion: "pipeline-v1"
        )
        progress = try await database.indexingProgress()
        XCTAssertEqual(progress.running, 1)
        XCTAssertEqual(progress.pending, 2)
        let jobsAfterOnlineReconcile = try await database.indexJobs()
        XCTAssertEqual(
            jobsAfterOnlineReconcile.first(where: { $0.id == interrupted.job.id })?.attemptCount,
            1
        )

        try await database.recoverInterruptedJobs(kind: .indexSegment)
        let recovered = try unwrapTarget(try await database.claimNextIndexJob())
        XCTAssertEqual(recovered.job.id, interrupted.job.id)
        XCTAssertEqual(recovered.job.attemptCount, 2)

        do {
            try await database.updateIndexJob(
                claim: interrupted.job.claimToken,
                stage: "stale-write"
            )
            XCTFail("陈旧 attempt 不应更新任务")
        } catch MediaDatabaseDerivationError.staleClaim {
            // expected
        }
        do {
            try await database.returnIndexJobToQueue(claim: interrupted.job.claimToken)
            XCTFail("陈旧 attempt 不应把新执行退回队列")
        } catch MediaDatabaseDerivationError.staleClaim {
            // expected
        }
        do {
            try await database.failIndexJob(
                claim: interrupted.job.claimToken,
                message: "stale failure"
            )
            XCTFail("陈旧 attempt 不应把新执行标记失败")
        } catch MediaDatabaseDerivationError.staleClaim {
            // expected
        }

        let output = SegmentIndexOutput(
            sourceFingerprint: recovered.asset.fingerprint,
            transcripts: [
                TranscriptSentenceDraft(
                    text: "我们在京都车站讨论晚饭。",
                    language: "Chinese",
                    startMS: 100,
                    endMS: 2_000,
                    timingSource: "forced_alignment_sentence"
                )
            ],
            ocr: [
                OCRObservationDraft(
                    text: "WELCOME 625000",
                    confidence: 0.93,
                    boxX: 0.1,
                    boxY: 0.2,
                    boxWidth: 0.3,
                    boxHeight: 0.1,
                    startMS: 500,
                    endMS: 1_500
                )
            ],
            frames: [
                SegmentFrameDraft(
                    timeMS: 500,
                    relativePath: "Frames/example/00.jpg",
                    perceptualHash: UInt64.max
                )
            ],
            embedding: EmbeddingVector(values: [0.6, 0.8], norm: 1),
            asrModelID: "asr-model",
            alignerModelID: "aligner-model",
            embeddingModelID: "embedding-model",
            runtimeVersion: "test"
        )
        do {
            try await database.commitIndexOutput(
                claim: interrupted.job.claimToken,
                segmentID: interrupted.segment.id,
                output: output,
                inputVersion: "pipeline-v1"
            )
            XCTFail("陈旧 attempt 不应提交建库产物")
        } catch MediaDatabaseDerivationError.staleClaim {
            // expected
        }
        let embeddingsBeforeValidCommit = try await database.storedEmbeddings(
            modelID: "embedding-model",
            inputVersion: "pipeline-v1"
        )
        XCTAssertTrue(embeddingsBeforeValidCommit.isEmpty)

        try await database.commitIndexOutput(
            claim: recovered.job.claimToken,
            segmentID: recovered.segment.id,
            output: output,
            inputVersion: "pipeline-v1"
        )

        progress = try await database.indexingProgress()
        XCTAssertEqual(progress.succeeded, 1)
        XCTAssertEqual(progress.pending, 2)
        let transcriptMatches = try await database.literalSearch(query: "京都车站")
        XCTAssertEqual(transcriptMatches.first?.segmentID, recovered.segment.id)
        let ocrMatches = try await database.literalSearch(query: "WELCOME")
        XCTAssertEqual(ocrMatches.first?.evidence.kind, .ocr)
        let embeddings = try await database.storedEmbeddings(
            modelID: "embedding-model",
            inputVersion: "pipeline-v1"
        )
        XCTAssertEqual(embeddings, [StoredEmbedding(segmentID: recovered.segment.id, values: [0.6, 0.8])])
        let frames = try await database.segmentFrames(segmentID: recovered.segment.id)
        XCTAssertEqual(frames.count, 1)
        let context = try await database.searchContext(segmentID: recovered.segment.id)
        XCTAssertEqual(context?.evidence.count, 2)

        try await database.reconcileIndexJobs(
            embeddingModelID: "embedding-model",
            inputVersion: "pipeline-v1"
        )
        let reconciledProgress = try await database.indexingProgress()
        XCTAssertEqual(reconciledProgress.total, 3)

        let changedAsset = sampleAsset(
            relativePath: "clip.mp4",
            durationMS: 45_001,
            fingerprint: "changed-fingerprint"
        )
        try await database.applyScan(
            rootID: root.id,
            result: MediaScanResult(
                assets: [changedAsset], unstableFileCount: 0, skippedFileCount: 0, errors: []
            )
        )
        let staleMatches = try await database.literalSearch(query: "京都车站")
        XCTAssertTrue(staleMatches.isEmpty)
        let staleEmbeddings = try await database.storedEmbeddings(
            modelID: "embedding-model",
            inputVersion: "pipeline-v1"
        )
        XCTAssertTrue(staleEmbeddings.isEmpty)
    }

    func testStaleIndexOutputDoesNotLeavePartialEvidence() async throws {
        let temporary = try TemporaryDirectory()
        let database = try MediaDatabase(url: temporary.url.appending(path: "test.sqlite"))
        let root = try await database.addLibraryRoot(
            path: temporary.url.path,
            bookmark: Data([10])
        )
        try await database.applyScan(
            rootID: root.id,
            result: MediaScanResult(
                assets: [sampleAsset(relativePath: "clip.mp4", durationMS: 10_000)],
                unstableFileCount: 0,
                skippedFileCount: 0,
                errors: []
            )
        )
        try await database.reconcileIndexJobs(
            embeddingModelID: "embedding-model",
            inputVersion: "pipeline-v1"
        )
        let target = try unwrapTarget(try await database.claimNextIndexJob())
        let stale = SegmentIndexOutput(
            sourceFingerprint: "different-fingerprint",
            transcripts: [],
            ocr: [],
            frames: [],
            embedding: EmbeddingVector(values: [1], norm: 1),
            asrModelID: "asr",
            alignerModelID: "aligner",
            embeddingModelID: "embedding-model",
            runtimeVersion: "test"
        )
        do {
            try await database.commitIndexOutput(
                claim: target.job.claimToken,
                segmentID: target.segment.id,
                output: stale,
                inputVersion: "pipeline-v1"
            )
            XCTFail("stale output should fail")
        } catch MediaDatabaseDerivationError.sourceChanged {
            // Expected.
        }
        let embeddings = try await database.storedEmbeddings(
            modelID: "embedding-model",
            inputVersion: "pipeline-v1"
        )
        XCTAssertTrue(embeddings.isEmpty)
        let matches = try await database.literalSearch(query: "anything")
        XCTAssertTrue(matches.isEmpty)
    }

    func testAssetLibraryDetailGroupsEvidencePerSegment() async throws {
        let temporary = try TemporaryDirectory()
        let database = try MediaDatabase(url: temporary.url.appending(path: "test.sqlite"))
        let root = try await database.addLibraryRoot(
            path: temporary.url.path,
            bookmark: Data([21, 22])
        )
        try await database.applyScan(
            rootID: root.id,
            result: MediaScanResult(
                assets: [sampleAsset(relativePath: "clip.mp4", durationMS: 45_001)],
                unstableFileCount: 0,
                skippedFileCount: 0,
                errors: []
            )
        )
        try await database.reconcileIndexJobs(
            embeddingModelID: "embedding-model",
            inputVersion: "pipeline-v1"
        )
        let assetValue = try await database.mediaAssets(rootID: root.id)
        let asset = try XCTUnwrap(assetValue.first)

        let empty = try await database.assetLibraryDetail(assetID: asset.id)
        XCTAssertEqual(empty.segments.map(\.segment.ordinal), [0, 1, 2])
        XCTAssertTrue(empty.segments.allSatisfy { !$0.isIndexed })
        XCTAssertTrue(empty.transcripts.isEmpty)
        XCTAssertTrue(empty.ocr.isEmpty)

        let target = try unwrapTarget(try await database.claimNextIndexJob())
        XCTAssertEqual(target.segment.ordinal, 0)
        let output = SegmentIndexOutput(
            sourceFingerprint: target.asset.fingerprint,
            transcripts: [
                TranscriptSentenceDraft(
                    text: "第一句话。",
                    language: "Chinese",
                    startMS: 100,
                    endMS: 900,
                    timingSource: "forced_alignment_sentence"
                ),
                TranscriptSentenceDraft(
                    text: "第二句话。",
                    language: "Chinese",
                    startMS: 1_000,
                    endMS: 2_000,
                    timingSource: "forced_alignment_sentence"
                )
            ],
            ocr: [
                OCRObservationDraft(
                    text: "WELCOME",
                    confidence: 0.9,
                    boxX: 0.1,
                    boxY: 0.2,
                    boxWidth: 0.3,
                    boxHeight: 0.1,
                    startMS: 500,
                    endMS: 1_500
                )
            ],
            frames: [
                SegmentFrameDraft(timeMS: 0, relativePath: "Frames/a/00.jpg", perceptualHash: 1),
                SegmentFrameDraft(timeMS: 1_000, relativePath: "Frames/a/01.jpg", perceptualHash: 2)
            ],
            embedding: EmbeddingVector(values: [0.6, 0.8], norm: 1),
            asrModelID: "asr-model",
            alignerModelID: "aligner-model",
            embeddingModelID: "embedding-model",
            runtimeVersion: "test"
        )
        try await database.commitIndexOutput(
            claim: target.job.claimToken,
            segmentID: target.segment.id,
            output: output,
            inputVersion: "pipeline-v1"
        )

        let detail = try await database.assetLibraryDetail(assetID: asset.id)
        XCTAssertEqual(detail.indexedSegmentCount, 1)
        XCTAssertEqual(detail.segments.first?.isIndexed, true)
        XCTAssertEqual(detail.segments.first?.frameCount, 2)
        let transcripts = try XCTUnwrap(detail.transcriptsBySegment[target.segment.id])
        XCTAssertEqual(transcripts.map(\.text), ["第一句话。", "第二句话。"])
        XCTAssertEqual(transcripts.first?.timingSource, "forced_alignment_sentence")
        XCTAssertEqual(transcripts.first?.language, "Chinese")
        let ocr = try XCTUnwrap(detail.ocrBySegment[target.segment.id])
        XCTAssertEqual(ocr.map(\.text), ["WELCOME"])
        XCTAssertEqual(ocr.first?.confidence ?? 0, 0.9, accuracy: 0.0001)
    }

    func testDescribeJobsReconcileClaimAndRequeue() async throws {
        let temporary = try TemporaryDirectory()
        let database = try MediaDatabase(url: temporary.url.appending(path: "test.sqlite"))
        let root = try await database.addLibraryRoot(
            path: temporary.url.path,
            bookmark: Data([31, 32])
        )
        try await database.applyScan(
            rootID: root.id,
            result: MediaScanResult(
                assets: [sampleAsset(relativePath: "clip.mp4", durationMS: 45_001)],
                unstableFileCount: 0,
                skippedFileCount: 0,
                errors: []
            )
        )
        try await database.reconcileIndexJobs(
            embeddingModelID: "embedding-model",
            inputVersion: "pipeline-v1"
        )

        // 未建库的片段不应该进描述队列。
        try await database.reconcileDescribeJobs()
        var describeProgress = try await database.describeProgress()
        XCTAssertEqual(describeProgress.total, 0)

        // 建库一个片段后，只有该片段进入描述队列。
        let target = try unwrapTarget(try await database.claimNextIndexJob())
        let output = SegmentIndexOutput(
            sourceFingerprint: target.asset.fingerprint,
            transcripts: [],
            ocr: [],
            frames: [
                SegmentFrameDraft(timeMS: 0, relativePath: "Frames/a/00.jpg", perceptualHash: 1)
            ],
            embedding: EmbeddingVector(values: [0.6, 0.8], norm: 1),
            asrModelID: "asr-model",
            alignerModelID: "aligner-model",
            embeddingModelID: "embedding-model",
            runtimeVersion: "test"
        )
        try await database.commitIndexOutput(
            claim: target.job.claimToken,
            segmentID: target.segment.id,
            output: output,
            inputVersion: "pipeline-v1"
        )
        try await database.reconcileDescribeJobs()
        describeProgress = try await database.describeProgress()
        XCTAssertEqual(describeProgress.total, 1)
        XCTAssertEqual(describeProgress.pending, 1)

        let describeTarget = try unwrapTarget(try await database.claimNextDescribeJob())
        XCTAssertEqual(describeTarget.segment.id, target.segment.id)
        try await database.reconcileDescribeJobs()
        describeProgress = try await database.describeProgress()
        XCTAssertEqual(describeProgress.running, 1)
        let jobsWhileDescribing = try await database.indexJobs()
        XCTAssertEqual(
            jobsWhileDescribing.first(where: { $0.id == describeTarget.job.id })?.attemptCount,
            describeTarget.job.attemptCount
        )

        // 保存描述与完成任务原子提交；配置变化（换模型/改 prompt）不自动重跑。
        try await commitTestDescription(database: database, target: describeTarget)
        try await database.reconcileDescribeJobs()
        describeProgress = try await database.describeProgress()
        XCTAssertEqual(describeProgress.pending, 0)
        let currentStale = try await database.staleDescriptionCount(
            descriptionModelID: "description-model",
            promptVersion: "prompt-v1"
        )
        XCTAssertEqual(currentStale, 0)
        let otherModelStale = try await database.staleDescriptionCount(
            descriptionModelID: "other-model",
            promptVersion: "prompt-v1"
        )
        XCTAssertEqual(otherModelStale, 1)
        let latest = try await database.latestDescription(segmentID: target.segment.id)
        XCTAssertEqual(latest?.modelID, "description-model")
        let descriptions = try await database.latestDescriptions(assetID: target.asset.id)
        XCTAssertEqual(descriptions.count, 1)
        XCTAssertEqual(descriptions[target.segment.id]?.description.summary, "概要")

        // 描述了但没保存（例如模型失败）时任务标记失败，可重试。
        try await database.requeueDescription(segmentID: target.segment.id)
        let retryTarget = try unwrapTarget(try await database.claimNextDescribeJob())
        try await database.failIndexJob(
            claim: retryTarget.job.claimToken,
            message: "模型不可用"
        )
        try await database.retryFailedJobs(kind: .describeSegment)
        describeProgress = try await database.describeProgress()
        XCTAssertEqual(describeProgress.pending, 1)
        XCTAssertEqual(describeProgress.failed, 0)

        // 全库手动刷新：只重跑配置过期的描述。
        try await database.requeueStaleDescriptions(
            descriptionModelID: "other-model",
            promptVersion: "prompt-v1"
        )
        describeProgress = try await database.describeProgress()
        XCTAssertEqual(describeProgress.pending, 1)
        let afterStaleRefresh = try await database.latestDescription(segmentID: target.segment.id)
        XCTAssertNil(afterStaleRefresh)

        // 视频级手动重跑：清空该视频描述并把任务重置。
        let claimed = try unwrapTarget(try await database.claimNextDescribeJob())
        try await commitTestDescription(database: database, target: claimed)
        try await database.requeueAssetDescriptions(assetID: target.asset.id)
        describeProgress = try await database.describeProgress()
        XCTAssertEqual(describeProgress.pending, 1)
        let afterAssetRefresh = try await database.latestDescription(segmentID: target.segment.id)
        XCTAssertNil(afterAssetRefresh)
    }

    func testRemoveRootCascadesAllDerivedData() async throws {
        let temporary = try TemporaryDirectory()
        let database = try MediaDatabase(url: temporary.url.appending(path: "test.sqlite"))
        let root = try await database.addLibraryRoot(
            path: temporary.url.path,
            bookmark: Data([41, 42])
        )
        try await database.applyScan(
            rootID: root.id,
            result: MediaScanResult(
                assets: [sampleAsset(relativePath: "clip.mp4", durationMS: 45_001)],
                unstableFileCount: 0,
                skippedFileCount: 0,
                errors: []
            )
        )
        try await database.reconcileIndexJobs(
            embeddingModelID: "embedding-model",
            inputVersion: "pipeline-v1"
        )
        let target = try unwrapTarget(try await database.claimNextIndexJob())
        try await database.commitIndexOutput(
            claim: target.job.claimToken,
            segmentID: target.segment.id,
            output: SegmentIndexOutput(
                sourceFingerprint: target.asset.fingerprint,
                transcripts: [
                    TranscriptSentenceDraft(
                        text: "一句话。",
                        language: "Chinese",
                        startMS: 0,
                        endMS: 1_000,
                        timingSource: "forced_alignment_sentence"
                    )
                ],
                ocr: [],
                frames: [
                    SegmentFrameDraft(timeMS: 0, relativePath: "Frames/x/00.jpg", perceptualHash: 1)
                ],
                embedding: EmbeddingVector(values: [0.6, 0.8], norm: 1),
                asrModelID: "asr-model",
                alignerModelID: "aligner-model",
                embeddingModelID: "embedding-model",
                runtimeVersion: "test"
            ),
            inputVersion: "pipeline-v1"
        )

        try await database.removeLibraryRoot(id: root.id)

        let roots = try await database.libraryRoots()
        XCTAssertTrue(roots.isEmpty)
        let assets = try await database.mediaAssets()
        XCTAssertTrue(assets.isEmpty)
        let matches = try await database.literalSearch(query: "一句话")
        XCTAssertTrue(matches.isEmpty)
        let embeddings = try await database.storedEmbeddings(
            modelID: "embedding-model",
            inputVersion: "pipeline-v1"
        )
        XCTAssertTrue(embeddings.isEmpty)
        let framePaths = try await database.referencedFrameRelativePaths()
        XCTAssertTrue(framePaths.isEmpty)
        let progress = try await database.indexingProgress()
        XCTAssertEqual(progress.total, 0)
    }

    func testBookmarkRenewalCannotRecreateRemovedRoot() async throws {
        let temporary = try TemporaryDirectory()
        let database = try MediaDatabase(url: temporary.url.appending(path: "test.sqlite"))
        let root = try await database.addLibraryRoot(
            path: temporary.url.path,
            bookmark: Data([1, 2, 3])
        )

        try await database.removeLibraryRoot(id: root.id)
        try await database.updateLibraryRootBookmark(id: root.id, bookmark: Data([4, 5, 6]))

        let roots = try await database.libraryRoots()
        XCTAssertTrue(roots.isEmpty)
    }

    func testRemovedAssetStaysExcludedAcrossRescan() async throws {
        let temporary = try TemporaryDirectory()
        let database = try MediaDatabase(url: temporary.url.appending(path: "test.sqlite"))
        let root = try await database.addLibraryRoot(
            path: temporary.url.path,
            bookmark: Data([43, 44])
        )
        let asset = sampleAsset(relativePath: "clip.mp4", durationMS: 45_001)
        try await database.applyScan(
            rootID: root.id,
            result: MediaScanResult(
                assets: [asset],
                unstableFileCount: 0,
                skippedFileCount: 0,
                errors: []
            )
        )
        let scannedValue = try await database.mediaAssets(rootID: root.id)
        let scanned = try XCTUnwrap(scannedValue.first)

        try await database.removeAsset(assetID: scanned.id)
        var assets = try await database.mediaAssets()
        XCTAssertTrue(assets.isEmpty)
        var segments = try await database.segments(assetID: scanned.id)
        XCTAssertTrue(segments.isEmpty)

        // 文件仍在目录中：重新扫描后依然保持排除，不重建片段。
        try await database.applyScan(
            rootID: root.id,
            result: MediaScanResult(
                assets: [asset],
                unstableFileCount: 0,
                skippedFileCount: 0,
                errors: []
            )
        )
        assets = try await database.mediaAssets()
        XCTAssertTrue(assets.isEmpty)
        segments = try await database.segments(assetID: scanned.id)
        XCTAssertTrue(segments.isEmpty)

        // 撤销排除后恢复可见并重建分段。
        try await database.restoreAsset(assetID: scanned.id)
        assets = try await database.mediaAssets()
        XCTAssertEqual(assets.count, 1)
        segments = try await database.segments(assetID: scanned.id)
        XCTAssertEqual(segments.count, 3)
    }

    func testRequeueResetsFinishedJobsAndCachedDescription() async throws {
        let temporary = try TemporaryDirectory()
        let database = try MediaDatabase(url: temporary.url.appending(path: "test.sqlite"))
        let root = try await database.addLibraryRoot(
            path: temporary.url.path,
            bookmark: Data([45, 46])
        )
        try await database.applyScan(
            rootID: root.id,
            result: MediaScanResult(
                assets: [sampleAsset(relativePath: "clip.mp4", durationMS: 20_000)],
                unstableFileCount: 0,
                skippedFileCount: 0,
                errors: []
            )
        )
        try await database.reconcileIndexJobs(
            embeddingModelID: "embedding-model",
            inputVersion: "pipeline-v1"
        )
        let target = try unwrapTarget(try await database.claimNextIndexJob())
        try await database.commitIndexOutput(
            claim: target.job.claimToken,
            segmentID: target.segment.id,
            output: SegmentIndexOutput(
                sourceFingerprint: target.asset.fingerprint,
                transcripts: [],
                ocr: [],
                frames: [
                    SegmentFrameDraft(timeMS: 0, relativePath: "Frames/y/00.jpg", perceptualHash: 1)
                ],
                embedding: EmbeddingVector(values: [0.6, 0.8], norm: 1),
                asrModelID: "asr-model",
                alignerModelID: "aligner-model",
                embeddingModelID: "embedding-model",
                runtimeVersion: "test"
            ),
            inputVersion: "pipeline-v1"
        )
        try await database.reconcileDescribeJobs()
        let describeTarget = try unwrapTarget(try await database.claimNextDescribeJob())
        try await commitTestDescription(
            database: database,
            target: describeTarget,
            inputVersion: "irrelevant"
        )
        var indexProgress = try await database.indexingProgress()
        XCTAssertEqual(indexProgress.succeeded, 1)
        var describeProgress = try await database.describeProgress()
        XCTAssertEqual(describeProgress.succeeded, 1)

        try await database.requeueAssetIndexJobs(assetID: target.asset.id)
        indexProgress = try await database.indexingProgress()
        XCTAssertEqual(indexProgress.pending, 1)

        try await database.requeueDescription(segmentID: target.segment.id)
        describeProgress = try await database.describeProgress()
        XCTAssertEqual(describeProgress.pending, 1)
        let cached = try await database.cachedDescription(
            segmentID: target.segment.id,
            inputVersion: "irrelevant"
        )
        XCTAssertNil(cached)
    }

    func testEvidenceLaneBecomesIdleWhenOnlyDescriptionsRemain() async throws {
        let temporary = try TemporaryDirectory()
        let database = try MediaDatabase(url: temporary.url.appending(path: "test.sqlite"))
        let root = try await database.addLibraryRoot(
            path: temporary.url.path,
            bookmark: Data([71, 72])
        )
        try await database.applyScan(
            rootID: root.id,
            result: MediaScanResult(
                assets: [sampleAsset(relativePath: "only.mp4", durationMS: 20_000)],
                unstableFileCount: 0,
                skippedFileCount: 0,
                errors: []
            )
        )
        try await database.reconcileIndexJobs(
            embeddingModelID: "embedding-model",
            inputVersion: "pipeline-v1"
        )
        let target = try unwrapTarget(try await database.claimNextIndexJob())
        try await database.commitIndexOutput(
            claim: target.job.claimToken,
            segmentID: target.segment.id,
            output: SegmentIndexOutput(
                sourceFingerprint: target.asset.fingerprint,
                transcripts: [],
                ocr: [],
                frames: [
                    SegmentFrameDraft(timeMS: 0, relativePath: "Frames/idle/00.jpg", perceptualHash: 1)
                ],
                embedding: EmbeddingVector(values: [0.6, 0.8], norm: 1),
                asrModelID: "asr-model",
                alignerModelID: "aligner-model",
                embeddingModelID: "embedding-model",
                runtimeVersion: "test"
            ),
            inputVersion: "pipeline-v1"
        )
        try await database.reconcileDescribeJobs()

        let evidenceClaim = try await database.claimNextIndexJob()
        XCTAssertEqual(evidenceClaim, .idle)
        let description = try unwrapTarget(try await database.claimNextDescribeJob())
        XCTAssertEqual(description.asset.id, target.asset.id)
    }

    func testEvidenceAndDescriptionLanesClaimIndependently() async throws {
        let temporary = try TemporaryDirectory()
        let database = try MediaDatabase(url: temporary.url.appending(path: "test.sqlite"))
        let root = try await database.addLibraryRoot(
            path: temporary.url.path,
            bookmark: Data([51, 52])
        )
        try await database.applyScan(
            rootID: root.id,
            result: MediaScanResult(
                assets: [
                    sampleAsset(
                        relativePath: "a.mp4",
                        durationMS: 20_000,
                        fileIdentifier: "file-a"
                    ),
                    sampleAsset(
                        relativePath: "b.mp4",
                        durationMS: 20_000,
                        fileIdentifier: "file-b"
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

        // 证据车道先认领 a.mp4。
        let first = try unwrapTarget(try await database.claimNextIndexJob())
        XCTAssertEqual(first.asset.relativePath, "a.mp4")

        // a 的证据提交、描述入队。
        try await database.commitIndexOutput(
            claim: first.job.claimToken,
            segmentID: first.segment.id,
            output: SegmentIndexOutput(
                sourceFingerprint: first.asset.fingerprint,
                transcripts: [],
                ocr: [],
                frames: [
                    SegmentFrameDraft(timeMS: 0, relativePath: "Frames/g/00.jpg", perceptualHash: 1)
                ],
                embedding: EmbeddingVector(values: [0.6, 0.8], norm: 1),
                asrModelID: "asr-model",
                alignerModelID: "aligner-model",
                embeddingModelID: "embedding-model",
                runtimeVersion: "test"
            ),
            inputVersion: "pipeline-v1"
        )
        try await database.reconcileDescribeJobs()
        let describeTarget = try unwrapTarget(try await database.claimNextDescribeJob())
        XCTAssertEqual(describeTarget.asset.relativePath, "a.mp4")

        // a 的描述仍在 running 时，证据车道独立认领 b，不受描述阻塞。
        let second = try unwrapTarget(try await database.claimNextIndexJob())
        XCTAssertEqual(second.asset.relativePath, "b.mp4")
        let progress = try await database.describeProgress()
        XCTAssertEqual(progress.running, 1)

        try await commitTestDescription(database: database, target: describeTarget)
    }

    func testDescriptionCommitRejectsChangedEvidenceRevision() async throws {
        let temporary = try TemporaryDirectory()
        let database = try MediaDatabase(url: temporary.url.appending(path: "test.sqlite"))
        let root = try await database.addLibraryRoot(
            path: temporary.url.path,
            bookmark: Data([81, 82])
        )
        try await database.applyScan(
            rootID: root.id,
            result: MediaScanResult(
                assets: [sampleAsset(relativePath: "revision.mp4", durationMS: 20_000)],
                unstableFileCount: 0,
                skippedFileCount: 0,
                errors: []
            )
        )
        try await database.reconcileIndexJobs(
            embeddingModelID: "embedding-model",
            inputVersion: "pipeline-v1"
        )
        let firstEvidence = try unwrapTarget(try await database.claimNextIndexJob())
        try await database.commitIndexOutput(
            claim: firstEvidence.job.claimToken,
            segmentID: firstEvidence.segment.id,
            output: SegmentIndexOutput(
                sourceFingerprint: firstEvidence.asset.fingerprint,
                transcripts: [],
                ocr: [],
                frames: [
                    SegmentFrameDraft(
                        timeMS: 0,
                        relativePath: "Frames/revision/old.jpg",
                        perceptualHash: 1
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
        try await database.reconcileDescribeJobs()
        let staleDescription = try unwrapTarget(try await database.claimNextDescribeJob())
        let staleRevision = try XCTUnwrap(staleDescription.descriptionInputRevision)

        try await database.requeueSegmentIndexJob(segmentID: firstEvidence.segment.id)
        let refreshedEvidence = try unwrapTarget(try await database.claimNextIndexJob())
        try await database.commitIndexOutput(
            claim: refreshedEvidence.job.claimToken,
            segmentID: refreshedEvidence.segment.id,
            output: SegmentIndexOutput(
                sourceFingerprint: refreshedEvidence.asset.fingerprint,
                transcripts: [
                    TranscriptSentenceDraft(
                        text: "新的证据",
                        language: "Chinese",
                        startMS: 0,
                        endMS: 1_000,
                        timingSource: "asr_block_fallback"
                    )
                ],
                ocr: [],
                frames: [
                    SegmentFrameDraft(
                        timeMS: 1_000,
                        relativePath: "Frames/revision/new.jpg",
                        perceptualHash: 2
                    )
                ],
                embedding: EmbeddingVector(values: [0.8, 0.6], norm: 1),
                asrModelID: "asr-model",
                alignerModelID: "aligner-model",
                embeddingModelID: "embedding-model",
                runtimeVersion: "test"
            ),
            inputVersion: "pipeline-v1"
        )
        let currentRevisionValue = try await database.descriptionInputRevision(
            segmentID: firstEvidence.segment.id
        )
        let currentRevision = try XCTUnwrap(currentRevisionValue)
        XCTAssertNotEqual(currentRevision, staleRevision)

        do {
            try await commitTestDescription(database: database, target: staleDescription)
            XCTFail("旧证据生成的描述不应覆盖新证据")
        } catch MediaDatabaseDerivationError.descriptionInputChanged {
            // expected
        }
        let rejectedDescription = try await database.latestDescription(
            segmentID: firstEvidence.segment.id
        )
        XCTAssertNil(rejectedDescription)

        try await database.returnIndexJobToQueue(
            claim: staleDescription.job.claimToken,
            stage: "input_changed"
        )
        let refreshedDescription = try unwrapTarget(try await database.claimNextDescribeJob())
        XCTAssertEqual(refreshedDescription.descriptionInputRevision, currentRevision)
        XCTAssertEqual(
            refreshedDescription.job.attemptCount,
            staleDescription.job.attemptCount + 1
        )
    }

    func testDescriptionReconcileUsesEvidenceRevisionInsteadOfWallClock() async throws {
        let temporary = try TemporaryDirectory()
        let database = try MediaDatabase(url: temporary.url.appending(path: "test.sqlite"))
        let root = try await database.addLibraryRoot(
            path: temporary.url.path,
            bookmark: Data([91, 92])
        )
        try await database.applyScan(
            rootID: root.id,
            result: MediaScanResult(
                assets: [sampleAsset(relativePath: "clock.mp4", durationMS: 20_000)],
                unstableFileCount: 0,
                skippedFileCount: 0,
                errors: []
            )
        )
        try await database.reconcileIndexJobs(
            embeddingModelID: "embedding-model",
            inputVersion: "pipeline-v1"
        )
        let timestamp = Date(timeIntervalSince1970: 1_700_000_000)
        let firstEvidence = try unwrapTarget(try await database.claimNextIndexJob(now: timestamp))
        try await database.commitIndexOutput(
            claim: firstEvidence.job.claimToken,
            segmentID: firstEvidence.segment.id,
            output: testIndexOutput(
                fingerprint: firstEvidence.asset.fingerprint,
                framePath: "Frames/clock/old.jpg"
            ),
            inputVersion: "pipeline-v1",
            now: timestamp
        )
        try await database.reconcileDescribeJobs(now: timestamp)
        let firstDescription = try unwrapTarget(
            try await database.claimNextDescribeJob(now: timestamp)
        )
        try await commitTestDescription(
            database: database,
            target: firstDescription,
            now: timestamp
        )

        // Simulate equal timestamps or a wall-clock rollback: only the immutable
        // derivation revision can prove that the evidence changed.
        try await database.requeueSegmentIndexJob(
            segmentID: firstEvidence.segment.id,
            now: timestamp
        )
        let refreshedEvidence = try unwrapTarget(
            try await database.claimNextIndexJob(now: timestamp)
        )
        try await database.commitIndexOutput(
            claim: refreshedEvidence.job.claimToken,
            segmentID: refreshedEvidence.segment.id,
            output: testIndexOutput(
                fingerprint: refreshedEvidence.asset.fingerprint,
                framePath: "Frames/clock/new.jpg"
            ),
            inputVersion: "pipeline-v1",
            now: timestamp.addingTimeInterval(-60)
        )
        try await database.reconcileDescribeJobs(now: timestamp)

        let progress = try await database.describeProgress()
        XCTAssertEqual(progress.pending, 1)
        let refreshedDescription = try unwrapTarget(
            try await database.claimNextDescribeJob(now: timestamp)
        )
        XCTAssertNotEqual(
            refreshedDescription.descriptionInputRevision,
            firstDescription.descriptionInputRevision
        )
    }

    func testReconcileAdoptsCurrentLegacyDescriptionWithoutModelRequeue() async throws {
        let temporary = try TemporaryDirectory()
        let url = temporary.url.appending(path: "test.sqlite")
        let database = try MediaDatabase(url: url)
        let root = try await database.addLibraryRoot(
            path: temporary.url.path,
            bookmark: Data([93, 94])
        )
        try await database.applyScan(
            rootID: root.id,
            result: MediaScanResult(
                assets: [sampleAsset(relativePath: "legacy-current.mp4", durationMS: 20_000)],
                unstableFileCount: 0,
                skippedFileCount: 0,
                errors: []
            )
        )
        try await database.reconcileIndexJobs(
            embeddingModelID: "embedding-model",
            inputVersion: "pipeline-v1"
        )
        let evidenceTime = Date(timeIntervalSince1970: 1_700_000_000)
        let evidence = try unwrapTarget(
            try await database.claimNextIndexJob(now: evidenceTime)
        )
        try await database.commitIndexOutput(
            claim: evidence.job.claimToken,
            segmentID: evidence.segment.id,
            output: testIndexOutput(
                fingerprint: evidence.asset.fingerprint,
                framePath: "Frames/legacy/current.jpg"
            ),
            inputVersion: "pipeline-v1",
            now: evidenceTime
        )
        try await database.reconcileDescribeJobs(now: evidenceTime)
        let description = try unwrapTarget(
            try await database.claimNextDescribeJob(now: evidenceTime)
        )
        try await commitTestDescription(
            database: database,
            target: description,
            now: evidenceTime.addingTimeInterval(10)
        )
        let expectedRevision = try XCTUnwrap(description.descriptionInputRevision)

        // Reproduce the shipped regression: an old description had no stored
        // revision and its already-complete job was changed to pending.
        do {
            let raw = try SQLiteConnection(url: url)
            try raw.execute(
                """
                UPDATE derivation_run
                SET parameters_json = json_remove(parameters_json, '$.input_revision')
                WHERE kind = 'description'
                """
            )
            try raw.execute(
                """
                UPDATE job
                SET status = 'pending', checkpoint_json = '{"stage":"description_outdated"}'
                WHERE kind = 'describe_segment'
                """
            )
        }

        try await database.reconcileDescribeJobs(
            now: evidenceTime.addingTimeInterval(20)
        )

        let progress = try await database.describeProgress()
        XCTAssertEqual(progress.succeeded, 1)
        XCTAssertEqual(progress.pending, 0)
        let retained = try await database.latestDescription(segmentID: evidence.segment.id)
        XCTAssertNotNil(retained)
        let storedRevision: String?
        do {
            let raw = try SQLiteConnection(url: url)
            let statement = try raw.prepare(
                """
                SELECT json_extract(dr.parameters_json, '$.input_revision')
                FROM segment_description d
                JOIN derivation_run dr ON dr.id = d.derivation_run_id
                WHERE d.segment_id = ?
                """
            )
            try statement.bind(.text(evidence.segment.id), at: 1)
            storedRevision = try statement.step() ? statement.text(at: 0) : nil
        }
        XCTAssertEqual(storedRevision, expectedRevision)
    }

    func testReconcileDoesNotAdoptLegacyDescriptionOlderThanEvidence() async throws {
        let temporary = try TemporaryDirectory()
        let url = temporary.url.appending(path: "test.sqlite")
        let database = try MediaDatabase(url: url)
        let root = try await database.addLibraryRoot(
            path: temporary.url.path,
            bookmark: Data([95, 96])
        )
        try await database.applyScan(
            rootID: root.id,
            result: MediaScanResult(
                assets: [sampleAsset(relativePath: "legacy-stale.mp4", durationMS: 20_000)],
                unstableFileCount: 0,
                skippedFileCount: 0,
                errors: []
            )
        )
        try await database.reconcileIndexJobs(
            embeddingModelID: "embedding-model",
            inputVersion: "pipeline-v1"
        )
        let initialTime = Date(timeIntervalSince1970: 1_700_000_000)
        let initialEvidence = try unwrapTarget(
            try await database.claimNextIndexJob(now: initialTime)
        )
        try await database.commitIndexOutput(
            claim: initialEvidence.job.claimToken,
            segmentID: initialEvidence.segment.id,
            output: testIndexOutput(
                fingerprint: initialEvidence.asset.fingerprint,
                framePath: "Frames/legacy/stale-old.jpg"
            ),
            inputVersion: "pipeline-v1",
            now: initialTime
        )
        try await database.reconcileDescribeJobs(now: initialTime)
        let oldDescription = try unwrapTarget(
            try await database.claimNextDescribeJob(now: initialTime)
        )
        try await commitTestDescription(
            database: database,
            target: oldDescription,
            now: initialTime.addingTimeInterval(10)
        )
        do {
            let raw = try SQLiteConnection(url: url)
            try raw.execute(
                """
                UPDATE derivation_run
                SET parameters_json = json_remove(parameters_json, '$.input_revision')
                WHERE kind = 'description'
                """
            )
        }

        let refreshedTime = initialTime.addingTimeInterval(60)
        try await database.requeueSegmentIndexJob(
            segmentID: initialEvidence.segment.id,
            now: refreshedTime
        )
        let refreshedEvidence = try unwrapTarget(
            try await database.claimNextIndexJob(now: refreshedTime)
        )
        try await database.commitIndexOutput(
            claim: refreshedEvidence.job.claimToken,
            segmentID: refreshedEvidence.segment.id,
            output: testIndexOutput(
                fingerprint: refreshedEvidence.asset.fingerprint,
                framePath: "Frames/legacy/stale-new.jpg"
            ),
            inputVersion: "pipeline-v1",
            now: refreshedTime
        )

        try await database.reconcileDescribeJobs(
            now: refreshedTime.addingTimeInterval(1)
        )

        let progress = try await database.describeProgress()
        XCTAssertEqual(progress.pending, 1)
        XCTAssertEqual(progress.succeeded, 0)
        let retained = try await database.latestDescription(segmentID: initialEvidence.segment.id)
        XCTAssertNotNil(retained)
    }

    func testRequeueStaleDescriptionsPreservesCurrentDescriptionsAndJobs() async throws {
        let temporary = try TemporaryDirectory()
        let database = try MediaDatabase(url: temporary.url.appending(path: "test.sqlite"))
        let root = try await database.addLibraryRoot(
            path: temporary.url.path,
            bookmark: Data([101, 102])
        )
        try await database.applyScan(
            rootID: root.id,
            result: MediaScanResult(
                assets: [
                    sampleAsset(
                        relativePath: "current.mp4",
                        durationMS: 20_000,
                        fingerprint: "current-fingerprint",
                        fileIdentifier: "current-file"
                    ),
                    sampleAsset(
                        relativePath: "stale.mp4",
                        durationMS: 20_000,
                        fingerprint: "stale-fingerprint",
                        fileIdentifier: "stale-file"
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
        for frameName in ["current", "stale"] {
            let target = try unwrapTarget(try await database.claimNextIndexJob())
            try await database.commitIndexOutput(
                claim: target.job.claimToken,
                segmentID: target.segment.id,
                output: testIndexOutput(
                    fingerprint: target.asset.fingerprint,
                    framePath: "Frames/selective/\(frameName).jpg"
                ),
                inputVersion: "pipeline-v1"
            )
        }
        try await database.reconcileDescribeJobs()

        var currentSegmentID = ""
        var staleSegmentID = ""
        for _ in 0..<2 {
            let target = try unwrapTarget(try await database.claimNextDescribeJob())
            if target.asset.relativePath == "current.mp4" {
                currentSegmentID = target.segment.id
                try await commitTestDescription(database: database, target: target)
            } else {
                staleSegmentID = target.segment.id
                try await commitTestDescription(
                    database: database,
                    target: target,
                    modelID: "old-description-model"
                )
            }
        }

        try await database.requeueStaleDescriptions(
            descriptionModelID: "description-model",
            promptVersion: "prompt-v1"
        )

        let currentDescription = try await database.latestDescription(segmentID: currentSegmentID)
        let staleDescription = try await database.latestDescription(segmentID: staleSegmentID)
        XCTAssertNotNil(currentDescription)
        XCTAssertNil(staleDescription)
        let jobs = try await database.indexJobs()
        XCTAssertEqual(
            jobs.first { $0.segmentID == currentSegmentID && $0.status == .succeeded }?.status,
            .succeeded
        )
        XCTAssertEqual(
            jobs.first { $0.segmentID == staleSegmentID && $0.status == .pending }?.status,
            .pending
        )
    }

    private func unwrapTarget(_ claim: JobClaim) throws -> SegmentIndexTarget {
        guard case .target(let target) = claim else {
            throw XCTSkip("预期可认领任务，实际：\(claim)")
        }
        return target
    }

    private func commitTestDescription(
        database: MediaDatabase,
        target: SegmentIndexTarget,
        inputVersion: String = "v1",
        summary: String = "概要",
        modelID: String = "description-model",
        promptVersion: String = "prompt-v1",
        now: Date = Date()
    ) async throws {
        guard let revision = target.descriptionInputRevision else {
            XCTFail("描述任务缺少输入 revision")
            return
        }
        try await database.commitDescription(
            claim: target.job.claimToken,
            segmentID: target.segment.id,
            sourceFingerprint: target.asset.fingerprint,
            expectedInputRevision: revision,
            modelID: modelID,
            runtimeVersion: "test",
            promptVersion: promptVersion,
            inputVersion: inputVersion,
            description: SegmentDescription(
                summary: summary,
                visibleDetails: [],
                uncertainty: []
            ),
            now: now
        )
    }

    private func testIndexOutput(
        fingerprint: String,
        framePath: String
    ) -> SegmentIndexOutput {
        SegmentIndexOutput(
            sourceFingerprint: fingerprint,
            transcripts: [],
            ocr: [],
            frames: [
                SegmentFrameDraft(timeMS: 0, relativePath: framePath, perceptualHash: 1)
            ],
            embedding: EmbeddingVector(values: [0.6, 0.8], norm: 1),
            asrModelID: "asr-model",
            alignerModelID: "aligner-model",
            embeddingModelID: "embedding-model",
            runtimeVersion: "test"
        )
    }

    private func sampleAsset(
        relativePath: String,
        durationMS: Int64,
        fingerprint: String = "stable-fingerprint",
        fileIdentifier: String = "stable-file-id"
    ) -> ScannedMediaAsset {
        ScannedMediaAsset(
            relativePath: relativePath,
            standardizedPath: "/tmp/\(relativePath)",
            fileIdentifier: fileIdentifier,
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
}

private final class TemporaryDirectory {
    let url: URL

    init() throws {
        url = FileManager.default.temporaryDirectory
            .appending(path: "media-memory-tests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    deinit {
        try? FileManager.default.removeItem(at: url)
    }
}
