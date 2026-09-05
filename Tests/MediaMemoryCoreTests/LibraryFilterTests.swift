import Foundation
@testable import MediaMemoryCore
import XCTest

final class LibraryFilterTests: XCTestCase {
    // MARK: 进度分桶

    func testNilSummaryClassifiesAsNotStarted() {
        XCTAssertEqual(AssetProcessingBucket.of(nil), .notStarted)
    }

    func testRunningLaneWinsOverFailuresAndPending() {
        let bucket = AssetProcessingBucket.of(
            summary(evidenceRunning: true, evidenceFailed: 1, describePending: 1)
        )
        XCTAssertEqual(bucket, .inProgress)
    }

    func testIdleFailuresClassifyAsFailed() {
        XCTAssertEqual(AssetProcessingBucket.of(summary(evidenceFailed: 1)), .failed)
    }

    func testPendingWorkClassifiesAsWaiting() {
        XCTAssertEqual(AssetProcessingBucket.of(summary(describePending: 1)), .waiting)
    }

    func testFullProductsClassifyAsCompleted() {
        XCTAssertEqual(AssetProcessingBucket.of(summary()), .completed)
    }

    func testIdleIncompleteProductsClassifyAsWaitingNotCompleted() {
        // 车道空闲但产物不完整（例如描述任务缺队）：不误报完成。
        XCTAssertEqual(AssetProcessingBucket.of(summary(describeSucceeded: 1)), .waiting)
    }

    func testZeroSegmentsWithoutJobsClassifiesAsNotStarted() {
        XCTAssertEqual(
            AssetProcessingBucket.of(
                summary(totalSegments: 0, evidenceSucceeded: 0, describeSucceeded: 0)
            ),
            .notStarted
        )
    }

    // MARK: 三阶段管线进度（媒体口径）

    func testPipelineFullyProcessedAssetCompletesAllStages() {
        let progress = LibraryPipelineProgress.compute(
            assets: [asset(path: "a.mp4")],
            summaries: ["a.mp4": summary()]
        )
        XCTAssertEqual(progress.totalAssets, 1)
        XCTAssertEqual(progress.segmentation.done, 1)
        XCTAssertEqual(progress.indexing.done, 1)
        XCTAssertEqual(progress.description.done, 1)
    }

    func testPipelineLegacyAssetWithoutSegmentJobCountsAsSettled() {
        // V1 遗留：有片段、有完整产物、无 segment_asset 任务——与桶的
        // completed 判定同源，三阶段都算完成。
        let progress = LibraryPipelineProgress.compute(
            assets: [asset(path: "a.mp4")],
            summaries: ["a.mp4": summary(segmentationStatus: nil)]
        )
        XCTAssertEqual(progress.segmentation.done, 1)
        XCTAssertEqual(progress.indexing.done, 1)
        XCTAssertEqual(progress.description.done, 1)
    }

    func testPipelinePendingResegmentationBlocksAllStages() {
        // 等待重分片的 V1 遗留资产：旧片段的历史成功不能算进新阶段进度。
        let progress = LibraryPipelineProgress.compute(
            assets: [asset(path: "a.mp4")],
            summaries: ["a.mp4": summary(segmentationStatus: .pending)]
        )
        XCTAssertEqual(progress.segmentation.done, 0)
        XCTAssertEqual(progress.indexing.done, 0)
        XCTAssertEqual(progress.description.done, 0)
    }

    func testPipelineRunningAndFailedSegmentation() {
        let assets = [asset(path: "run.mp4"), asset(path: "fail.mp4")]
        let progress = LibraryPipelineProgress.compute(
            assets: assets,
            summaries: [
                "run.mp4": summary(evidenceSucceeded: 0, describeSucceeded: 0, segmentationStatus: .running),
                "fail.mp4": summary(evidenceSucceeded: 0, describeSucceeded: 0, segmentationStatus: .failed),
            ]
        )
        XCTAssertEqual(progress.segmentation.active, 1)
        XCTAssertEqual(progress.segmentation.failed, 1)
        XCTAssertEqual(progress.segmentation.done, 0)
        XCTAssertEqual(progress.indexing.done, 0)
    }

    func testPipelineEvidenceFailureShowsInIndexingStageOnly() {
        let progress = LibraryPipelineProgress.compute(
            assets: [asset(path: "a.mp4")],
            summaries: ["a.mp4": summary(evidenceSucceeded: 1, evidenceFailed: 1)]
        )
        XCTAssertEqual(progress.segmentation.done, 1)
        XCTAssertEqual(progress.indexing.done, 0)
        XCTAssertEqual(progress.indexing.failed, 1)
        XCTAssertEqual(progress.description.done, 1)
        XCTAssertEqual(progress.description.failed, 0)
    }

    func testPipelineRunningDescribeCountsActiveNotDone() {
        let progress = LibraryPipelineProgress.compute(
            assets: [asset(path: "a.mp4")],
            summaries: ["a.mp4": summary(describeSucceeded: 1, describeRunning: true)]
        )
        XCTAssertEqual(progress.description.active, 1)
        XCTAssertEqual(progress.description.done, 0)
    }

    func testPipelineSkipsAssetsWithoutSummaryButKeepsDenominator() {
        let progress = LibraryPipelineProgress.compute(
            assets: [asset(path: "done.mp4"), asset(path: "fresh.mp4")],
            summaries: ["done.mp4": summary()]
        )
        XCTAssertEqual(progress.totalAssets, 2)
        XCTAssertEqual(progress.segmentation.done, 1)
        XCTAssertEqual(progress.indexing.done, 1)
        XCTAssertEqual(progress.description.done, 1)
    }

    // MARK: 时长分桶

    func testDurationBucketBoundariesAreLeftClosedRightOpen() {
        XCTAssertEqual(DurationBucket.of(durationMS: 29_999), .under30s)
        XCTAssertEqual(DurationBucket.of(durationMS: 30_000), .from30sTo5m)
        XCTAssertEqual(DurationBucket.of(durationMS: 299_999), .from30sTo5m)
        XCTAssertEqual(DurationBucket.of(durationMS: 300_000), .from5mTo20m)
        XCTAssertEqual(DurationBucket.of(durationMS: 1_199_999), .from5mTo20m)
        XCTAssertEqual(DurationBucket.of(durationMS: 1_200_000), .over20m)
    }

    // MARK: 谓词

    func testKindFilterExcludesOtherKind() {
        let filter = LibraryFilter(mediaKind: .image)
        XCTAssertTrue(filter.matches(asset: asset(path: "a.jpg", kind: .image), summary: nil))
        XCTAssertFalse(filter.matches(asset: asset(path: "b.mp4"), summary: nil))
    }

    func testDurationFilterExcludesImagesEvenWithNominalDuration() {
        let filter = LibraryFilter(duration: .under30s)
        // 图片的名义 1 秒时长对筛选不可见：时长条件激活时图片一律不匹配。
        XCTAssertFalse(filter.matches(asset: asset(path: "a.jpg", kind: .image, durationMS: 1_000), summary: nil))
        XCTAssertTrue(filter.matches(asset: asset(path: "b.mp4", durationMS: 12_000), summary: nil))
        XCTAssertFalse(filter.matches(asset: asset(path: "c.mp4", durationMS: 900_000), summary: nil))
    }

    func testPathQueryMatchesFullPathCaseInsensitive() {
        let filter = LibraryFilter(pathQuery: "Trip")
        XCTAssertTrue(filter.matches(asset: asset(path: "2026 trip/IMG_0001.mp4"), summary: nil))
        XCTAssertFalse(filter.matches(asset: asset(path: "home/meeting.mp4"), summary: nil))
    }

    func testWhitespaceOnlyPathQueryMatchesEverything() {
        let filter = LibraryFilter(pathQuery: "   ")
        XCTAssertTrue(filter.matches(asset: asset(path: "a.mp4"), summary: nil))
        XCTAssertFalse(filter.isActive)
    }

    func testDimensionsCombineWithAnd() {
        let filter = LibraryFilter(mediaKind: .video, progress: .completed)
        XCTAssertTrue(filter.matches(asset: asset(path: "a.mp4"), summary: summary()))
        XCTAssertFalse(filter.matches(asset: asset(path: "b.mp4"), summary: summary(evidenceFailed: 1)))
        XCTAssertFalse(filter.matches(asset: asset(path: "c.jpg", kind: .image), summary: summary()))
    }

    func testIsActiveReflectsEveryDimension() {
        XCTAssertFalse(LibraryFilter().isActive)
        XCTAssertTrue(LibraryFilter(mediaKind: .video).isActive)
        XCTAssertTrue(LibraryFilter(progress: .completed).isActive)
        XCTAssertTrue(LibraryFilter(duration: .under30s).isActive)
        XCTAssertTrue(LibraryFilter(pathQuery: "a").isActive)
    }

    // MARK: 计数

    func testCountsAreGlobalAndSplitByDimension() {
        let assets = [
            asset(path: "short.mp4", durationMS: 10_000),
            asset(path: "long.mp4", durationMS: 2_000_000),
            asset(path: "photo.jpg", kind: .image),
        ]
        let summaries = [
            "short.mp4": summary(),
            "long.mp4": summary(evidenceFailed: 1),
        ]
        let counts = LibraryFilterCounts.compute(assets: assets, summaries: summaries)
        XCTAssertEqual(counts.totalCount, 3)
        XCTAssertEqual(counts.videoCount, 2)
        XCTAssertEqual(counts.imageCount, 1)
        XCTAssertEqual(counts.progress[.completed], 1)
        XCTAssertEqual(counts.progress[.failed], 1)
        XCTAssertEqual(counts.progress[.notStarted], 1)
        XCTAssertEqual(counts.duration[.under30s], 1)
        XCTAssertEqual(counts.duration[.over20m], 1)
    }

    // MARK: 排序

    func testDefaultNameSortPreservesDatabaseOrder() {
        let assets = [asset(path: "B.mp4"), asset(path: "a.mp4")]
        // 数据库按 NOCASE 原序传入；名称排序不重排，避免两套默认视图。
        XCTAssertEqual(LibrarySort().applied(assets).map(\.relativePath), ["B.mp4", "a.mp4"])
        XCTAssertEqual(LibrarySort(key: .name, ascending: false).applied(assets).map(\.relativePath), ["a.mp4", "B.mp4"])
    }

    func testFileSizeSortIsStableOnTiesInBothDirections() {
        let first = asset(path: "first.mp4", fileSize: 100)
        let second = asset(path: "second.mp4", fileSize: 300)
        let third = asset(path: "third.mp4", fileSize: 100)
        let assets = [first, second, third]
        XCTAssertEqual(
            LibrarySort(key: .fileSize, ascending: true).applied(assets).map(\.relativePath),
            ["first.mp4", "third.mp4", "second.mp4"]
        )
        XCTAssertEqual(
            LibrarySort(key: .fileSize, ascending: false).applied(assets).map(\.relativePath),
            ["second.mp4", "first.mp4", "third.mp4"]
        )
    }

    func testDurationSortKeepsImagesAfterVideosRegardlessOfDirection() {
        let video1 = asset(path: "v1.mp4", durationMS: 500_000)
        let video2 = asset(path: "v2.mp4", durationMS: 90_000)
        let image = asset(path: "i.jpg", kind: .image, durationMS: 1_000)
        let assets = [image, video1, video2]
        XCTAssertEqual(
            LibrarySort(key: .duration, ascending: true).applied(assets).map(\.relativePath),
            ["v2.mp4", "v1.mp4", "i.jpg"]
        )
        XCTAssertEqual(
            LibrarySort(key: .duration, ascending: false).applied(assets).map(\.relativePath),
            ["v1.mp4", "v2.mp4", "i.jpg"]
        )
    }

    func testModifiedAndFirstSeenSortByKey() {
        let early = asset(
            path: "early.mp4",
            modified: Date(timeIntervalSince1970: 100),
            firstSeen: Date(timeIntervalSince1970: 10)
        )
        let late = asset(
            path: "late.mp4",
            modified: Date(timeIntervalSince1970: 200),
            firstSeen: Date(timeIntervalSince1970: 20)
        )
        XCTAssertEqual(
            LibrarySort(key: .modifiedAt, ascending: false).applied([early, late]).map(\.relativePath),
            ["late.mp4", "early.mp4"]
        )
        XCTAssertEqual(
            LibrarySort(key: .firstSeenAt, ascending: true).applied([late, early]).map(\.relativePath),
            ["early.mp4", "late.mp4"]
        )
    }

    func testSortIsDefaultOnlyForPlainNameAscending() {
        XCTAssertTrue(LibrarySort().isDefault)
        XCTAssertFalse(LibrarySort(key: .fileSize).isDefault)
        XCTAssertFalse(LibrarySort(key: .name, ascending: false).isDefault)
    }

    // MARK: 夹具

    private func asset(
        path: String,
        kind: MediaKind = .video,
        durationMS: Int64 = 0,
        fileSize: Int64 = 0,
        modified: Date = Date(timeIntervalSince1970: 0),
        firstSeen: Date = Date(timeIntervalSince1970: 0)
    ) -> MediaAssetRecord {
        MediaAssetRecord(
            id: path,
            rootID: "root",
            relativePath: path,
            standardizedPath: "/lib/\(path)",
            fileSize: fileSize,
            modificationDate: modified,
            durationMS: durationMS,
            videoTrackCount: kind == .video ? 1 : 0,
            audioTrackCount: 0,
            isPlayable: true,
            fingerprint: "fp-\(path)",
            status: .ready,
            errorMessage: nil,
            firstSeenAt: firstSeen,
            lastSeenAt: firstSeen,
            mediaKind: kind
        )
    }

    private func summary(
        totalSegments: Int = 2,
        evidenceSucceeded: Int = 2,
        evidencePending: Int = 0,
        evidenceRunning: Bool = false,
        evidenceFailed: Int = 0,
        describeSucceeded: Int = 2,
        describePending: Int = 0,
        describeRunning: Bool = false,
        describeFailed: Int = 0,
        segmentationStatus: JobStatus? = .succeeded
    ) -> AssetProcessingSummary {
        AssetProcessingSummary(
            assetID: "asset",
            segmentationStatus: segmentationStatus,
            segmentationStage: nil,
            totalSegments: totalSegments,
            indexedSegments: evidenceSucceeded,
            evidenceSucceeded: evidenceSucceeded,
            evidencePending: evidencePending,
            evidenceRunning: evidenceRunning,
            evidenceFailed: evidenceFailed,
            currentStage: nil,
            currentSegmentOrdinal: nil,
            describeSucceeded: describeSucceeded,
            describePending: describePending,
            describeRunning: describeRunning,
            describeFailed: describeFailed
        )
    }
}
