import Foundation
@testable import MediaMemoryCore
import XCTest

/// 轻量刷新管线：元数据分类（planScanRefresh）与刷新提交
/// （applyScanRefresh）的语义，以及扫描器的枚举/定向探测两端。
final class ScanRefreshTests: XCTestCase {
    func testPlanScanRefreshClassifiesUnchangedChangedAndNew() async throws {
        let context = try await TestContext.make()
        let asset = context.asset(relativePath: "a.mp4", fingerprint: "fp-a")
        try await context.database.applyScan(
            rootID: context.rootID,
            result: context.completeResult(assets: [asset])
        )

        let plan = try await context.database.planScanRefresh(
            rootID: context.rootID,
            candidates: [
                context.candidate(relativePath: "a.mp4"),
                context.candidate(relativePath: "b.mp4"),
                context.candidate(
                    relativePath: "drifted.mp4",
                    modificationDate: Date(timeIntervalSince1970: 1_700_000_005)
                )
            ]
        )

        XCTAssertEqual(plan.unchangedRelativePaths, ["a.mp4"])
        XCTAssertEqual(
            plan.toProbe.map(\.relativePath),
            ["b.mp4", "drifted.mp4"],
            "新增与元数据漂移的文件必须重新探测"
        )
    }

    func testAuthoritativeRefreshMarksDeletedMissingAndKeepsUnchangedIntact() async throws {
        let context = try await TestContext.make()
        let kept = context.asset(relativePath: "kept.mp4", fingerprint: "fp-kept")
        let deleted = context.asset(relativePath: "deleted.mp4", fingerprint: "fp-deleted")
        try await context.database.applyScan(
            rootID: context.rootID,
            result: context.completeResult(assets: [kept, deleted])
        )
        let keptID = try await context.database.mediaAssets()
            .first { $0.relativePath == kept.relativePath }!.id
        let segmentsBefore = try await context.database.segments(assetID: keptID)
        XCTAssertFalse(segmentsBefore.isEmpty, "前置：就绪资产应有旧版兜底片段")

        let refreshAt = Date(timeIntervalSince1970: 1_700_000_500)
        try await context.database.applyScanRefresh(
            rootID: context.rootID,
            unchangedRelativePaths: [kept.relativePath],
            probed: context.completeResult(assets: []),
            isAuthoritative: true,
            scannedAt: refreshAt
        )

        let assets = try await context.database.mediaAssets()
        XCTAssertEqual(assets.map(\.relativePath), ["kept.mp4"], "缺失资产不再出现在库视图")
        XCTAssertEqual(assets.first?.lastSeenAt, refreshAt)
        let segmentsAfter = try await context.database.segments(assetID: keptID)
        XCTAssertEqual(segmentsAfter, segmentsBefore, "未变化资产不得重建片段")
        let roots = try await context.database.libraryRoots()
        XCTAssertEqual(roots.first?.lastScanAt, refreshAt, "权威刷新应刷新 last_scan_at")
    }

    func testNonAuthoritativeRefreshDoesNotInvalidateAnything() async throws {
        let context = try await TestContext.make()
        let kept = context.asset(relativePath: "kept.mp4", fingerprint: "fp-kept")
        let other = context.asset(relativePath: "other.mp4", fingerprint: "fp-other")
        try await context.database.applyScan(
            rootID: context.rootID,
            result: context.completeResult(assets: [kept, other])
        )
        let scanAtBefore = try await context.database.libraryRoots().first?.lastScanAt

        try await context.database.applyScanRefresh(
            rootID: context.rootID,
            unchangedRelativePaths: [kept.relativePath],
            probed: context.completeResult(assets: []),
            isAuthoritative: false,
            scannedAt: Date(timeIntervalSince1970: 1_700_000_600)
        )

        let assets = try await context.database.mediaAssets()
        XCTAssertEqual(
            Set(assets.map(\.relativePath)),
            ["kept.mp4", "other.mp4"],
            "不确定刷新不得判定任何资产缺失"
        )
        let scanAtAfter = try await context.database.libraryRoots().first?.lastScanAt
        XCTAssertEqual(
            scanAtAfter,
            scanAtBefore,
            "不确定刷新不得推进 last_scan_at"
        )
    }

    func testRefreshReprobesMissingAssetAndRestoresEvidenceWithoutRebuild() async throws {
        let context = try await TestContext.make()
        let asset = context.asset(relativePath: "clip.mp4", fingerprint: "fp-clip")
        try await context.database.applyScan(
            rootID: context.rootID,
            result: context.completeResult(assets: [asset])
        )
        try await context.database.reconcileIndexJobs(
            embeddingModelID: "embedding-model",
            inputVersion: "pipeline-v1"
        )
        guard case let .target(target) = try await context.database.claimNextIndexJob() else {
            return XCTFail("预期可认领建库任务")
        }
        try await context.database.commitIndexOutput(
            claim: target.job.claimToken,
            segmentID: target.segment.id,
            output: SegmentIndexOutput(
                sourceFingerprint: target.asset.fingerprint,
                transcripts: [
                    TranscriptSentenceDraft(
                        text: "刷新后应保留的证据",
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
        let segmentsBefore = try await context.database.segments(assetID: target.asset.id)

        // 文件消失：全量权威扫描判定缺失。
        try await context.database.applyScan(
            rootID: context.rootID,
            result: context.completeResult(assets: [])
        )
        // 文件原样回归：轻量刷新把它分类为待探测（状态不是就绪）。
        let plan = try await context.database.planScanRefresh(
            rootID: context.rootID,
            candidates: [context.candidate(relativePath: "clip.mp4")]
        )
        XCTAssertEqual(plan.toProbe.map(\.relativePath), ["clip.mp4"])

        try await context.database.applyScanRefresh(
            rootID: context.rootID,
            unchangedRelativePaths: plan.unchangedRelativePaths,
            probed: context.completeResult(assets: [asset]),
            isAuthoritative: true
        )

        let matches = try await context.database.literalSearch(query: "证据")
        XCTAssertEqual(matches.count, 1)
        let embeddings = try await context.database.storedEmbeddings(
            modelID: "embedding-model",
            inputVersion: "pipeline-v1"
        )
        XCTAssertEqual(embeddings.count, 1)
        let segmentsAfter = try await context.database.segments(assetID: target.asset.id)
        XCTAssertEqual(segmentsAfter, segmentsBefore, "同指纹恢复不得重建片段")
        let available = try await context.database.isIndexTargetAvailable(
            assetID: target.asset.id,
            sourceFingerprint: asset.fingerprint
        )
        XCTAssertTrue(available)
    }

    func testRefreshPreservesExclusionMarkerForUnchangedExcludedAsset() async throws {
        let context = try await TestContext.make()
        let asset = context.asset(relativePath: "clip.mp4", fingerprint: "fp-clip")
        try await context.database.applyScan(
            rootID: context.rootID,
            result: context.completeResult(assets: [asset])
        )
        try await context.database.removeAsset(
            assetID: try await context.database.mediaAssets()[0].id
        )

        let plan = try await context.database.planScanRefresh(
            rootID: context.rootID,
            candidates: [context.candidate(relativePath: "clip.mp4")]
        )
        XCTAssertEqual(
            plan.unchangedRelativePaths,
            ["clip.mp4"],
            "排除标记只是隐藏，元数据一致仍属未变化"
        )
        try await context.database.applyScanRefresh(
            rootID: context.rootID,
            unchangedRelativePaths: plan.unchangedRelativePaths,
            probed: context.completeResult(assets: []),
            isAuthoritative: true
        )

        let assets = try await context.database.mediaAssets()
        XCTAssertTrue(assets.isEmpty, "用户明确移除的视频不得因刷新回到库中")
    }

    func testEnumerateRootListsCandidatesWithoutProbing() async throws {
        let directory = try TestMediaFixture.directoryURL()
        let video = try TestMediaFixture.videoURL()
        let snapshot = try FileFingerprint.snapshot(for: video)

        let enumeration = try MediaScanner().enumerateRoot(rootURL: directory)

        XCTAssertTrue(enumeration.isComplete)
        XCTAssertTrue(enumeration.errors.isEmpty)
        let candidate = try XCTUnwrap(
            enumeration.candidates.first { $0.standardizedPath == video.standardizedFileURL.path }
        )
        XCTAssertEqual(candidate.fileSize, snapshot.fileSize)
        XCTAssertEqual(candidate.modificationDate, snapshot.modificationDate)
        XCTAssertEqual(candidate.fileIdentifier, snapshot.fileIdentifier)
        XCTAssertEqual(candidate.relativePath, video.lastPathComponent)
    }

    func testProbeFilesProbesOnlyRequestedCandidates() async throws {
        let directory = try TestMediaFixture.directoryURL()
        let video = try TestMediaFixture.videoURL()
        let scanner = MediaScanner()
        let enumeration = try scanner.enumerateRoot(rootURL: directory)
        let candidate = try XCTUnwrap(
            enumeration.candidates.first { $0.standardizedPath == video.standardizedFileURL.path }
        )

        let empty = try await scanner.probeFiles(rootURL: directory, candidates: [])
        XCTAssertTrue(empty.assets.isEmpty)
        XCTAssertTrue(empty.isAuthoritativeComplete)

        let probed = try await scanner.probeFiles(rootURL: directory, candidates: [candidate])
        XCTAssertEqual(probed.assets.count, 1, "只探测给定候选，未变化的文件不被打开")
        let asset = try XCTUnwrap(probed.assets.first)
        XCTAssertEqual(asset.standardizedPath, video.standardizedFileURL.path)
        XCTAssertEqual(asset.status, .ready)
        XCTAssertGreaterThan(asset.durationMS, 0)
        XCTAssertTrue(probed.isAuthoritativeComplete)
    }
}

/// 每个用例一套临时数据库；资产/候选默认值彼此一致，便于构造
/// "未变化"的组合。
private final class TestContext {
    let database: MediaDatabase
    let rootID: String
    let temporary: URL

    private static let baseDirectory = "/tmp/refresh-fixture"
    private static let defaultMtime = Date(timeIntervalSince1970: 1_700_000_000)

    private init(database: MediaDatabase, rootID: String, temporary: URL) {
        self.database = database
        self.rootID = rootID
        self.temporary = temporary
    }

    static func make() async throws -> TestContext {
        let temporary = FileManager.default.temporaryDirectory
            .appending(path: "media-memory-scan-refresh-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        let database = try MediaDatabase(url: temporary.appending(path: "test.sqlite"))
        let root = try await database.addLibraryRoot(path: "/tmp/refresh", bookmark: Data([1]))
        return TestContext(database: database, rootID: root.id, temporary: temporary)
    }

    deinit {
        try? FileManager.default.removeItem(at: temporary)
    }

    func asset(
        relativePath: String,
        fingerprint: String
    ) -> ScannedMediaAsset {
        ScannedMediaAsset(
            relativePath: relativePath,
            standardizedPath: "\(Self.baseDirectory)/\(relativePath)",
            fileIdentifier: "id-\(relativePath)",
            fileSize: 1_024,
            modificationDate: Self.defaultMtime,
            durationMS: 20_000,
            videoTrackCount: 1,
            audioTrackCount: 1,
            isPlayable: true,
            fingerprint: fingerprint,
            status: .ready,
            errorMessage: nil
        )
    }

    func candidate(
        relativePath: String,
        modificationDate: Date = TestContext.defaultMtime
    ) -> MediaScanCandidate {
        MediaScanCandidate(
            relativePath: relativePath,
            standardizedPath: "\(Self.baseDirectory)/\(relativePath)",
            fileIdentifier: "id-\(relativePath)",
            fileSize: 1_024,
            modificationDate: modificationDate
        )
    }

    func completeResult(assets: [ScannedMediaAsset]) -> MediaScanResult {
        MediaScanResult(
            assets: assets,
            unstableFileCount: 0,
            skippedFileCount: 0,
            errors: []
        )
    }
}
