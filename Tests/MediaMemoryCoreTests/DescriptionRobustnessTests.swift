import Foundation
@testable import MediaMemoryCore
import XCTest

/// 描述缓存的健壮性与数据性过期标记：单条损坏 JSON 不放大为整页失败，
/// 证据重新提交后描述在重新生成前被标记过期。
final class DescriptionRobustnessTests: XCTestCase {
    func testCorruptDescriptionRowDoesNotFailAssetPageNorCacheHit() async throws {
        let fixture = try await DescriptionFixture.make()
        // 把第一段描述的缓存 JSON 写坏。
        try fixture.writeSQL(
            "UPDATE segment_description SET description_json = 'not-json' WHERE segment_id = ?",
            bindings: [.text(fixture.firstSegmentID)]
        )

        let descriptions = try await fixture.database.latestDescriptions(assetID: fixture.assetID)
        XCTAssertEqual(
            Array(descriptions.keys),
            [fixture.secondSegmentID],
            "坏行只跳过自身，不得让整个视频的描述加载失败"
        )
        XCTAssertTrue(descriptions[fixture.secondSegmentID]?.isEvidenceCurrent ?? false)

        let corruptLatest = try await fixture.database.latestDescription(
            segmentID: fixture.firstSegmentID
        )
        XCTAssertNil(corruptLatest, "单条坏 JSON 的 latest 读取返回 nil 而非抛错")

        let corruptCacheHit = try await fixture.database.cachedDescription(
            segmentID: fixture.firstSegmentID,
            inputVersion: "desc-v1"
        )
        XCTAssertNil(corruptCacheHit, "坏缓存按无缓存处理，触发重新生成并自愈覆盖")
    }

    func testEvidenceRecommitMarksDescriptionStaleUntilRegenerated() async throws {
        let fixture = try await DescriptionFixture.make()
        let initial = try await fixture.database.latestDescriptions(assetID: fixture.assetID)
        XCTAssertTrue(initial[fixture.firstSegmentID]?.isEvidenceCurrent ?? false)
        XCTAssertTrue(initial[fixture.secondSegmentID]?.isEvidenceCurrent ?? false)

        // 证据车道重新提交第一段：新的向量 derivation 即新的证据 revision。
        try await fixture.recommitEvidence(segmentID: fixture.firstSegmentID)
        let afterEvidence = try await fixture.database.latestDescriptions(assetID: fixture.assetID)
        XCTAssertFalse(
            afterEvidence[fixture.firstSegmentID]?.isEvidenceCurrent ?? true,
            "证据已更新而描述未重新生成时必须标记过期"
        )
        XCTAssertTrue(
            afterEvidence[fixture.secondSegmentID]?.isEvidenceCurrent ?? false,
            "未受影响片段不得误标"
        )

        // 描述按新 revision 重新生成后标记消失。
        try await fixture.saveDescription(segmentID: fixture.firstSegmentID)
        let regenerated = try await fixture.database.latestDescriptions(assetID: fixture.assetID)
        XCTAssertTrue(regenerated[fixture.firstSegmentID]?.isEvidenceCurrent ?? false)
    }
}

// MARK: - 夹具

private final class DescriptionTemporaryDirectory {
    let url: URL

    init() throws {
        url = FileManager.default.temporaryDirectory
            .appending(
                path: "description-robustness-tests-\(UUID().uuidString)",
                directoryHint: .isDirectory
            )
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    deinit {
        try? FileManager.default.removeItem(at: url)
    }
}

private struct DescriptionFixture {
    let temporary: DescriptionTemporaryDirectory
    let database: MediaDatabase
    let assetID: String
    let firstSegmentID: String
    let secondSegmentID: String

    static func make() async throws -> DescriptionFixture {
        let temporary = try DescriptionTemporaryDirectory()
        let database = try MediaDatabase(url: temporary.url.appending(path: "test.sqlite"))
        let root = try await database.addLibraryRoot(
            path: temporary.url.path,
            bookmark: Data([31])
        )
        try await database.applyScan(
            rootID: root.id,
            result: MediaScanResult(
                assets: [
                    ScannedMediaAsset(
                        relativePath: "descriptions.mp4",
                        standardizedPath: "/offline-volume/descriptions.mp4",
                        fileIdentifier: nil,
                        fileSize: 1_024,
                        modificationDate: Date(timeIntervalSince1970: 100),
                        durationMS: 20_000,
                        videoTrackCount: 1,
                        audioTrackCount: 1,
                        isPlayable: true,
                        fingerprint: "description-fingerprint",
                        status: .ready,
                        errorMessage: nil
                    )
                ],
                unstableFileCount: 0,
                skippedFileCount: 0,
                errors: []
            )
        )
        let assets = try await database.mediaAssets(rootID: root.id)
        let asset = try XCTUnwrap(assets.first)

        _ = try await database.reconcileSegmentationJobs(algorithmVersion: "semantic-desc")
        guard case let .target(claim) = try await database.claimNextSegmentationJob() else {
            throw DescriptionFixtureError.emptyClaim
        }
        try await database.commitSegmentation(
            claim: claim.job.claimToken,
            assetID: asset.id,
            sourceFingerprint: asset.fingerprint,
            algorithmVersion: "semantic-desc",
            parametersJSON: "{\"algorithm_version\":\"semantic-desc\"}",
            segments: [
                .init(startMS: 0, endMS: 10_000),
                .init(startMS: 10_000, endMS: 20_000)
            ]
        )
        let segments = try await database.segments(assetID: asset.id)
        XCTAssertEqual(segments.count, 2)
        let firstSegmentID = try XCTUnwrap(segments.first { $0.ordinal == 0 }?.id)
        let secondSegmentID = try XCTUnwrap(segments.first { $0.ordinal == 1 }?.id)

        let fixture = DescriptionFixture(
            temporary: temporary,
            database: database,
            assetID: asset.id,
            firstSegmentID: firstSegmentID,
            secondSegmentID: secondSegmentID
        )
        try await fixture.commitEvidence(segmentID: firstSegmentID)
        try await fixture.commitEvidence(segmentID: secondSegmentID)
        try await fixture.saveDescription(segmentID: firstSegmentID)
        try await fixture.saveDescription(segmentID: secondSegmentID)
        return fixture
    }

    private func nextIndexClaim(segmentID: String) async throws -> SegmentIndexTarget {
        try await database.reconcileIndexJobs(
            embeddingModelID: "embedding-model",
            inputVersion: "pipeline-v1"
        )
        guard case let .target(target) = try await database.claimNextIndexJob() else {
            throw DescriptionFixtureError.emptyClaim
        }
        XCTAssertEqual(target.segment.id, segmentID)
        return target
    }

    func commitEvidence(segmentID: String) async throws {
        let target = try await nextIndexClaim(segmentID: segmentID)
        try await database.commitIndexOutput(
            claim: target.job.claimToken,
            segmentID: segmentID,
            output: SegmentIndexOutput(
                sourceFingerprint: target.asset.fingerprint,
                transcripts: [],
                ocr: [],
                frames: [
                    .init(
                        timeMS: target.segment.startMS,
                        relativePath: "Frames/descriptions/\(target.segment.ordinal).jpg",
                        perceptualHash: 1
                    )
                ],
                embedding: EmbeddingVector(values: [0.6, 0.8], norm: 1),
                asrModelID: "asr-model",
                alignerModelID: "aligner-model",
                embeddingModelID: "embedding-model",
                runtimeVersion: "description-test"
            ),
            inputVersion: "pipeline-v1"
        )
    }

    /// 证据重提交：重排队 → 认领 → 再次提交（产生新的 derivation revision）。
    func recommitEvidence(segmentID: String) async throws {
        try await database.requeueSegmentIndexJob(segmentID: segmentID)
        try await commitEvidence(segmentID: segmentID)
    }

    func saveDescription(segmentID: String) async throws {
        let revision = try await database.descriptionInputRevision(segmentID: segmentID)
        let current = try XCTUnwrap(revision)
        try await database.saveDescription(
            segmentID: segmentID,
            sourceFingerprint: "description-fingerprint",
            expectedInputRevision: current,
            modelID: "description-model",
            runtimeVersion: "description-test",
            promptVersion: "prompt-v1",
            inputVersion: "desc-v1",
            description: SegmentDescription(
                summary: "第\(segmentID == firstSegmentID ? "一" : "二")段的可观察内容。",
                visibleDetails: [],
                uncertainty: []
            )
        )
    }

    func writeSQL(_ sql: String, bindings: [SQLiteValue]) throws {
        let connection = try SQLiteConnection(url: temporary.url.appending(path: "test.sqlite"))
        let statement = try connection.prepare(sql)
        for (offset, value) in bindings.enumerated() {
            try statement.bind(value, at: Int32(offset + 1))
        }
        _ = try statement.step()
    }
}

private enum DescriptionFixtureError: Error {
    case emptyClaim
}
